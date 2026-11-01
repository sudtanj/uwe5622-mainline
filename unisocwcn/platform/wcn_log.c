#define pr_fmt(fmt) "WCN: " fmt

#include <linux/cdev.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/poll.h>
#include <linux/slab.h>
#include <linux/wait.h>

#include "rdc_debug.h"
#include "wcn_glb.h"
#include "wcn_misc.h"

#define MDBG_WRITE_SIZE			(64)
#define WCN_LOG_MAJOR 255
static int wcn_log_major = WCN_LOG_MAJOR;
static struct class		*wcnlog_class;

struct wcnlog_dev {
	struct cdev cdev;
	int			major;
	int			minor;
};

struct mdbg_device_t *mdbg_dev;
wait_queue_head_t	mdbg_wait;

int wake_up_log_wait(void)
{
	if (!mdbg_dev->exit_flag) {
		wake_up_interruptible(&mdbg_dev->rxwait);
		wake_up_interruptible(&mdbg_wait);
	}

	return 0;
}

void wcnlog_clear_log(void)
{
	if (mdbg_dev->ring_dev->ring->rp
		!= mdbg_dev->ring_dev->ring->wp) {
		pr_info("log:%ld left in ringbuf not read\n",
			(long int)(mdbg_dev->ring_dev->ring->wp -
			mdbg_dev->ring_dev->ring->rp));
		mdbg_ring_clear(mdbg_dev->ring_dev->ring);
	}
}

static int wcnlog_open(struct inode *inode, struct file *filp)
{
	struct wcnlog_dev *dev;

	int minor = iminor(filp->f_path.dentry->d_inode);
	int minor1 = iminor(inode);
	int major = imajor(inode);

	pr_info("minor=%d,minor1=%d,major=%d\n", minor, minor1, major);

	if (mdbg_dev->exit_flag) {
		pr_info("%s exit!\n", __func__);
		return -EIO;
	}

	dev = container_of(inode->i_cdev, struct wcnlog_dev, cdev);
	filp->private_data = dev;

	pr_debug("%s z=%d,major=%d,minor = %d\n", __func__,
		dev->cdev.dev, MAJOR(dev->cdev.dev), MINOR(dev->cdev.dev));

	if (mdbg_dev->open_count != 0)
		pr_err("open count %d\n", mdbg_dev->open_count);

	mdbg_dev->open_count++;

	return 0;
}

static int wcnlog_release(struct inode *inode, struct file *filp)
{
	struct wcnlog_dev *dev = filp->private_data;

	pr_info("%s z=%d,major=%d,minor = %d\n", __func__,
		dev->cdev.dev, MAJOR(dev->cdev.dev), MINOR(dev->cdev.dev));
	mdbg_dev->open_count--;

	return 0;
}

static ssize_t wcnlog_read(struct file *filp,
		char __user *buf, size_t count, loff_t *ppos)
{
	long int read_size;
	int timeout = -1;
	int rval = 0;
	static unsigned int dum_send_size;
	struct wcnlog_dev *dev = filp->private_data;

	if (mdbg_dev->exit_flag) {
		pr_info("%s exit!\n", __func__);
		return -EIO;
	}

	if (filp->f_flags & O_NONBLOCK)
		timeout = 0;

	pr_debug("%s timeout=%d,major=%d, minor=%d\n", __func__,
		timeout, dev->major, dev->minor);

	pr_debug("%s z=%d,major=%d,minor = %d\n", __func__, dev->cdev.dev,
		MAJOR(dev->cdev.dev), MINOR(dev->cdev.dev));
	/* count :100K-log, 32K-mem ;cat :4096 */
	pr_debug("%s len = %ld\n", __func__, (long)count);
	if ((functionmask[7] & CP2_FLAG_YLOG) == 1)
		return -EIO;

	if (MINOR(dev->cdev.dev) == 1) {
		pr_info("unsupported to read slog_wcn1: BT audio data\n");
		return -EPERM;
	}

	if (filp->f_flags & O_NONBLOCK)
		timeout = 0;

	if (count > MDBG_RX_RING_SIZE)
		count = MDBG_RX_RING_SIZE;

	if (timeout < 0) {
		/* when kernel go to sleep, it return -512 */
		rval = wait_event_interruptible(mdbg_wait,
				(mdbg_content_len() > 0));
		if (rval < 0)
			pr_info("wait interrupted=%d\n", rval);
	}

	mutex_lock(&mdbg_dev->mdbg_lock);
	read_size = mdbg_receive((void __force *)buf, (long)count);
	if (sprdwcn_bus_get_carddump_status() == 1) {
		dum_send_size += read_size;
		pr_info("read_size = %ld dum_total_size= %d,remainder =%ld\n",
				read_size, dum_send_size, mdbg_content_len());
	}
	/* read_size = log1040 or mem32K, 1024 */
	if (read_size > 0) {
		pr_debug("Show %ld bytes data.\n", read_size);
		rval = read_size;
	} else if (read_size == 0)
		rval = -EAGAIN;
	else {
		rval = read_size;
		pr_debug("log read error %d\n", rval);
	}
	mutex_unlock(&mdbg_dev->mdbg_lock);

	return rval;

}

static ssize_t wcnlog_write(struct file *filp,
		const char __user *buf, size_t count, loff_t *ppos)
{
	long int sent_size = 0;
	char *p_data = NULL;

	if (mdbg_dev->exit_flag) {
		pr_info("%s exit!\n", __func__);
		return -EIO;
	}

	pr_info("%s count=%ld\n", __func__, (long)count);
	if (count > MDBG_WRITE_SIZE) {
		pr_err("mdbg_write count > MDBG_WRITE_SIZE\n");
		return -ENOMEM;
	}

	if (NULL == buf || 0 == count) {
		pr_err("Param Error!");
		return count;
	}

	p_data = memdup_user(buf, count);
	mutex_lock(&mdbg_dev->mdbg_lock);
	sent_size = mdbg_send_atcmd(p_data, count, WCN_ATCMD_LOG);
	mutex_unlock(&mdbg_dev->mdbg_lock);
	kfree(p_data);

	pr_debug("sent_size = %ld\n", sent_size);

	return sent_size;
}

static __poll_t wcnlog_poll(struct file *filp, poll_table *wait)
{
	__poll_t mask = 0;

	if ((!mdbg_dev) || (mdbg_dev->exit_flag)) {
		pr_info("%s exit!\n", __func__);
		mask |= EPOLLIN | EPOLLERR;
		return mask;
	}
	poll_wait(filp, &mdbg_dev->rxwait, wait);
	if (mdbg_content_len() > 0)
		mask |= EPOLLIN | EPOLLRDNORM;

	return mask;
}

static long wcnlog_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	if (mdbg_dev->exit_flag) {
		pr_info("%s exit!\n", __func__);
		return -EIO;
	}

	return 0;
}

static const struct file_operations wcnlog_fops = {
	.open		= wcnlog_open,
	.release	= wcnlog_release,
	.read		= wcnlog_read,
	.write		= wcnlog_write,
	.poll		= wcnlog_poll,
	.unlocked_ioctl	= wcnlog_ioctl,
	.owner		= THIS_MODULE,
	.llseek		= default_llseek,
};

static int wcnlog_register_device(struct wcnlog_dev *dev, int index)
{
	dev_t devno;
	int ret;

	devno = MKDEV(wcn_log_major, index);
	dev->cdev.owner = THIS_MODULE;
	cdev_init(&dev->cdev, &wcnlog_fops);
	ret = cdev_add(&dev->cdev, devno, 1);
	if (ret != 0) {
		unregister_chrdev_region(devno, 1);
		pr_err("Failed to add wcn log cdev\n");
		return ret;
	}
	dev->major = MAJOR(devno);
	dev->minor = MINOR(devno);
	pr_debug("log dev major=%d,minor=%d\n", dev->major, dev->minor);
	device_create(wcnlog_class, NULL,
			MKDEV(MAJOR(devno), MINOR(devno)),
			NULL, "%s%d", "slog_wcn", index);

	return 0;
}

int log_cdev_init(void)
{
	int ret = -1;
	int	i;
	int iflag = -1;
	dev_t devno;

	struct wcnlog_dev *dev[WCN_LOG_MAX_MINOR] = {NULL};

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
	wcnlog_class = class_create("slog_wcn");
#else
	wcnlog_class = class_create(THIS_MODULE, "slog_wcn");
#endif
	if (IS_ERR(wcnlog_class))
		return PTR_ERR(wcnlog_class);

	devno = MKDEV(wcn_log_major, 0);
	if (wcn_log_major)
		ret = register_chrdev_region(devno,
				WCN_LOG_MAX_MINOR, "wcnlog");
	if (ret < 0) {
		pr_info("failed to apply for static device number");
		ret = alloc_chrdev_region(&devno, 0,
				WCN_LOG_MAX_MINOR, "wcnlog");
		wcn_log_major = MAJOR(devno);
	}

	if (ret < 0) {
		pr_err("failed to apply for device number");
		return ret;
	}

	for (i = 0; i < WCN_LOG_MAX_MINOR; i++) {
		dev[i] = kmalloc(sizeof(struct wcnlog_dev), GFP_KERNEL);
		if (!dev[i]) {
			pr_err("failed alloc mem!\n");
			continue;
		}
		iflag = 1;
		ret = wcnlog_register_device(dev[i], i);
		if (ret != 0) {
			kfree(dev[i]);
			dev[i] = NULL;
			continue;
		}
		mdbg_dev->dev[i] = dev[i];
	}
	/* kmalloc fail */
	if (iflag == -1) {
		unregister_chrdev_region(devno, 1);
		ret = -1;
	}

	return ret;
}

int log_cdev_exit(void)
{
	struct wcnlog_dev *dev[WCN_LOG_MAX_MINOR];
	int i;

	pr_info("%s\n", __func__);

	for (i = 0; i < WCN_LOG_MAX_MINOR; i++) {
		dev[i] = mdbg_dev->dev[i];
		if (!dev[i])
			continue;
		device_destroy(wcnlog_class, (&(dev[i]->cdev))->dev);
		cdev_del(&(dev[i]->cdev));
		kfree(dev[i]);
		dev[i] = NULL;
	}

	class_destroy(wcnlog_class);

	unregister_chrdev_region(MKDEV(wcn_log_major, 0), WCN_LOG_MAX_MINOR);

	return 0;
}

int log_dev_init(void)
{
	int err;

	pr_debug("ENTER.\n");
	mdbg_dev = kzalloc(sizeof(struct mdbg_device_t), GFP_KERNEL);
	if (!mdbg_dev)
		return -ENOMEM;

	mdbg_dev->open_count = 0;
	mutex_init(&mdbg_dev->mdbg_lock);
	init_waitqueue_head(&mdbg_dev->rxwait);
	init_waitqueue_head(&mdbg_wait);
	err = mdbg_ring_init();
	if (err < 0)
		return -ENOMEM;

	log_cdev_init();
	mdbg_dev->exit_flag = 0;

	return 0;
}

int log_dev_exit(void)
{
	mdbg_dev->exit_flag = 1;
	log_cdev_exit();

	/* free for old mdbg_dev */
	mdbg_ring_remove();
	mutex_destroy(&mdbg_dev->mdbg_lock);
	kfree(mdbg_dev);

	return 0;
}
