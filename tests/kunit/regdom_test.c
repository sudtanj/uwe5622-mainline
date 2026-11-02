// SPDX-License-Identifier: GPL-2.0
/*
 * KUnit: country code to regulatory domain lookup and the frequency to
 * rule matching in unisocwifi/reg_domain.c.
 */
#include "../../unisocwifi/reg_domain.c"
#include <kunit/test.h>

static void regdom_known_countries(struct kunit *test)
{
	static const char * const cc[] = { "00", "US", "CN", "NL", "CZ", "JP", "TR" };
	char alpha2[3];
	int i;

	for (i = 0; i < ARRAY_SIZE(cc); i++) {
		const struct ieee80211_regdomain *rd;

		strscpy(alpha2, cc[i], sizeof(alpha2));
		rd = getRegdomainFromSprdDB(alpha2);
		KUNIT_ASSERT_NOT_NULL(test, rd);
		KUNIT_EXPECT_GT_MSG(test, rd->n_reg_rules, 0, "%s", cc[i]);
	}
}

static void regdom_unknown_is_world(struct kunit *test)
{
	char alpha2[3] = "ZZ";
	const struct ieee80211_regdomain *rd = getRegdomainFromSprdDB(alpha2);

	KUNIT_ASSERT_NOT_NULL(test, rd);
	KUNIT_EXPECT_EQ(test, rd->alpha2[0], '0');
	KUNIT_EXPECT_EQ(test, rd->alpha2[1], '0');
}

static void regdom_rules_well_formed(struct kunit *test)
{
	static const char * const cc[] = { "00", "US", "CN", "NL", "CZ", "JP", "TR" };
	char alpha2[3];
	int i, r;

	for (i = 0; i < ARRAY_SIZE(cc); i++) {
		const struct ieee80211_regdomain *rd;

		strscpy(alpha2, cc[i], sizeof(alpha2));
		rd = getRegdomainFromSprdDB(alpha2);
		for (r = 0; r < rd->n_reg_rules; r++) {
			const struct ieee80211_freq_range *f = &rd->reg_rules[r].freq_range;

			KUNIT_EXPECT_LT_MSG(test, f->start_freq_khz, f->end_freq_khz,
					    "%s rule %d", cc[i], r);
			/* AUTO_BW rules may list more than the band; the core trims them */
			if (rd->reg_rules[r].flags & NL80211_RRF_AUTO_BW)
				continue;
			KUNIT_EXPECT_LE_MSG(test, f->max_bandwidth_khz,
					    f->end_freq_khz - f->start_freq_khz,
					    "%s rule %d", cc[i], r);
		}
	}
}

static void regdom_freq_lookup(struct kunit *test)
{
	char alpha2[3] = "00";
	const struct ieee80211_regdomain *world = getRegdomainFromSprdDB(alpha2);
	const struct ieee80211_reg_rule *rr;

	/* channel 1 */
	rr = sprd_freq_reg_info_regd(MHZ_TO_KHZ(2412), world);
	KUNIT_ASSERT_FALSE(test, IS_ERR(rr));
	KUNIT_EXPECT_LE(test, rr->freq_range.start_freq_khz, MHZ_TO_KHZ(2402));
	KUNIT_EXPECT_GE(test, rr->freq_range.end_freq_khz, MHZ_TO_KHZ(2422));
	/* channel 14 is 802.11b only */
	rr = sprd_freq_reg_info_regd(MHZ_TO_KHZ(2484), world);
	KUNIT_ASSERT_FALSE(test, IS_ERR(rr));
	KUNIT_EXPECT_TRUE(test, rr->flags & NL80211_RRF_NO_OFDM);
	/* 60 GHz is in no rule's band */
	rr = sprd_freq_reg_info_regd(MHZ_TO_KHZ(60480), world);
	KUNIT_EXPECT_EQ(test, PTR_ERR(rr), -ERANGE);
	KUNIT_EXPECT_EQ(test, PTR_ERR(sprd_freq_reg_info_regd(MHZ_TO_KHZ(2412), NULL)), -EINVAL);
}

static struct kunit_case regdom_cases[] = {
	KUNIT_CASE(regdom_known_countries),
	KUNIT_CASE(regdom_unknown_is_world),
	KUNIT_CASE(regdom_rules_well_formed),
	KUNIT_CASE(regdom_freq_lookup),
	{}
};

static struct kunit_suite regdom_suite = {
	.name = "uwe5622_regdom",
	.test_cases = regdom_cases,
};
kunit_test_suite(regdom_suite);
