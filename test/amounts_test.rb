# frozen_string_literal: true

require_relative "test_helper"

class AmountsTest < Minitest::Test
  def test_parses_human_decimals_into_raw_units
    assert_equal "1500000", Paymos::Amounts.parse_units("1.5", 6)
    assert_equal "1000000", Paymos::Amounts.parse_units("1", 6)
    assert_equal "1", Paymos::Amounts.parse_units("0.000001", 6)
    assert_equal "12", Paymos::Amounts.parse_units("12", 0)
  end

  def test_rejects_anything_that_is_not_a_non_negative_decimal
    ["-1", "abc", "", "1,5", "1.2.3", " ", "1."].each do |bad|
      assert_raises(Paymos::PaymosError) { Paymos::Amounts.parse_units(bad, 6) }
    end
    assert_raises(Paymos::PaymosError) { Paymos::Amounts.parse_units("1.1234567", 6) }
  end

  def test_survives_amounts_a_float_would_round
    raw = Paymos::Amounts.parse_units("123456789.123456789123456789", 18)
    assert_equal "123456789123456789123456789", raw
    assert_equal "123456789.123456789123456789", Paymos::Amounts.format_units(raw, 18)
  end

  def test_formats_raw_units_back_dropping_trailing_zeros
    assert_equal "1.5", Paymos::Amounts.format_units("1500000", 6)
    assert_equal "1", Paymos::Amounts.format_units("1000000", 6)
    assert_equal "0.000001", Paymos::Amounts.format_units("1", 6)
    assert_equal "12", Paymos::Amounts.format_units("12", 0)
  end

  def test_round_trips
    [["1.5", 6], ["0.000001", 6], ["1000", 18], ["7", 0]].each do |human, dec|
      assert_equal human, Paymos::Amounts.format_units(Paymos::Amounts.parse_units(human, dec), dec)
    end
  end
end
