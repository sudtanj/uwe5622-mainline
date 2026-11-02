// SPDX-License-Identifier: GPL-2.0
/*
 * KUnit: the parser for the chip's RF configuration file
 * (wifi_<chipid>_<n>ant.ini, e.g. wifi_2355b001_1ant.ini), in
 * unisocwifi/rf_marlin3.c. The file is read into a buffer and handed to
 * wifi_nvm_buf_operate(), which splits it into lines, get_cmd_par() turns a
 * line into a key and up to 512 numbers, and the key's entry in
 * g_config_table says where in struct wifi_conf_t the numbers go.
 */
#include "../../unisocwifi/rf_marlin3.c"
#include <kunit/test.h>

static struct wifi_conf_t *parse(struct kunit *test, const char *text)
{
	struct wifi_conf_t *conf = kunit_kzalloc(test, sizeof(*conf), GFP_KERNEL);
	char *buf = kunit_kzalloc(test, strlen(text) + 1, GFP_KERNEL);

	KUNIT_ASSERT_NOT_NULL(test, conf);
	KUNIT_ASSERT_NOT_NULL(test, buf);
	strcpy(buf, text);
	KUNIT_EXPECT_EQ(test, wifi_nvm_buf_operate(buf, strlen(buf), conf), 0);
	return conf;
}

static void rf_ini_basic(struct kunit *test)
{
	struct wifi_conf_t *c = parse(test, "Major = 2\nMinor = 17\n");

	KUNIT_EXPECT_EQ(test, c->version.major, 2);
	KUNIT_EXPECT_EQ(test, c->version.minor, 17);
}

static void rf_ini_crlf_comments_unknown(struct kunit *test)
{
	struct wifi_conf_t *c = parse(test,
		"#-----------------------------------\r\n"
		"# Major = 9\r\n"
		"Not_A_Key = 5\r\n"
		"Minor = 3\r\n");

	KUNIT_EXPECT_EQ(test, c->version.major, 0);
	KUNIT_EXPECT_EQ(test, c->version.minor, 3);
}

static void rf_ini_hex_and_negative(struct kunit *test)
{
	struct wifi_conf_t *c = parse(test, "TxChain_Mask = 0x3\nrf_config = -1, 0x10, 7\n");

	KUNIT_EXPECT_EQ(test, c->board_config.txchain_mask, 3);
	KUNIT_EXPECT_EQ(test, c->rf_config.rf_data_len, 3);
	KUNIT_EXPECT_EQ(test, (s8)c->rf_config.rf_data[0], -1);
	KUNIT_EXPECT_EQ(test, c->rf_config.rf_data[1], 0x10);
	KUNIT_EXPECT_EQ(test, c->rf_config.rf_data[2], 7);
}

static void rf_ini_last_line_without_newline(struct kunit *test)
{
	/* the buffer is not NUL-terminated in the driver either */
	struct wifi_conf_t *c = parse(test, "Major = 1\nMinor = 4");

	KUNIT_EXPECT_EQ(test, c->version.major, 1);
	KUNIT_EXPECT_EQ(test, c->version.minor, 4);
}

static void rf_ini_bad_number_ignored(struct kunit *test)
{
	struct nvm_cali_cmd *cmd = kunit_kzalloc(test, sizeof(*cmd), GFP_KERNEL);
	char line[] = "Major = 1z\n";

	KUNIT_ASSERT_NOT_NULL(test, cmd);
	get_cmd_par(line, cmd);
	/* "1z" is not a number: it must not be stored as one */
	KUNIT_EXPECT_EQ(test, cmd->num, 0);
}

static void rf_ini_value_count_capped(struct kunit *test)
{
	struct nvm_cali_cmd *cmd = kunit_kzalloc(test, sizeof(*cmd), GFP_KERNEL);
	size_t n = ARRAY_SIZE(cmd->par) + 8, i;
	char *line = kunit_kzalloc(test, 16 + 2 * n + 2, GFP_KERNEL);
	char *p;

	KUNIT_ASSERT_NOT_NULL(test, cmd);
	KUNIT_ASSERT_NOT_NULL(test, line);
	p = line + sprintf(line, "rf_config =");
	for (i = 0; i < n; i++)
		p += sprintf(p, " 1");
	strcpy(p, "\n");
	get_cmd_par(line, cmd);
	/* par[] holds 512 values; more must be dropped, not written past it */
	KUNIT_EXPECT_LE(test, cmd->num, (int)ARRAY_SIZE(cmd->par));
}

static void rf_ini_long_key_contained(struct kunit *test)
{
	struct nvm_cali_cmd *cmd = kunit_kzalloc(test, sizeof(*cmd), GFP_KERNEL);
	char line[100 + 2];

	KUNIT_ASSERT_NOT_NULL(test, cmd);
	memset(line, 'K', 100);
	strcpy(line + 100, "\n");
	get_cmd_par(line, cmd);
	/* itm[] is 64 bytes: a longer key must not run into par[] */
	KUNIT_EXPECT_EQ(test, cmd->par[0], 0);
	KUNIT_EXPECT_EQ(test, cmd->par[1], 0);
}

static void rf_ini_long_token_contained(struct kunit *test)
{
	struct nvm_cali_cmd *cmd = kunit_kzalloc(test, sizeof(*cmd), GFP_KERNEL);
	char line[16 + 130 + 2];

	KUNIT_ASSERT_NOT_NULL(test, cmd);
	/*
	 * get_cmd_par() collects each token in a 128-byte stack buffer. A
	 * 130-digit value overruns it by three bytes, into KASAN's redzone
	 * (reported, and the test fails) but not into the stack canary.
	 */
	strcpy(line, "Major = ");
	memset(line + 8, '1', 130);
	strcpy(line + 8 + 130, "\n");
	get_cmd_par(line, cmd);
	KUNIT_EXPECT_LE(test, cmd->num, 1);
}

static void rf_ini_type_classes(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, find_type('a'), 1);
	KUNIT_EXPECT_EQ(test, find_type('_'), 1);
	KUNIT_EXPECT_EQ(test, find_type('7'), 2);
	KUNIT_EXPECT_EQ(test, find_type('-'), 2);
	KUNIT_EXPECT_EQ(test, find_type('x'), 3);
	KUNIT_EXPECT_EQ(test, find_type('#'), 4);
	KUNIT_EXPECT_EQ(test, find_type('\n'), 4);
	KUNIT_EXPECT_EQ(test, find_type('='), 0);
	KUNIT_EXPECT_EQ(test, find_type(','), 0);
}

static struct kunit_case rf_ini_cases[] = {
	KUNIT_CASE(rf_ini_type_classes),
	KUNIT_CASE(rf_ini_basic),
	KUNIT_CASE(rf_ini_crlf_comments_unknown),
	KUNIT_CASE(rf_ini_hex_and_negative),
	KUNIT_CASE(rf_ini_last_line_without_newline),
	KUNIT_CASE(rf_ini_bad_number_ignored),
	KUNIT_CASE(rf_ini_value_count_capped),
	KUNIT_CASE(rf_ini_long_key_contained),
	KUNIT_CASE(rf_ini_long_token_contained),
	{}
};

static struct kunit_suite rf_ini_suite = {
	.name = "uwe5622_rf_ini",
	.test_cases = rf_ini_cases,
};
kunit_test_suite(rf_ini_suite);
