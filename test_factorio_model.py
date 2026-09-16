import unittest

from factorio_model import (
    balance,
    belt_capacity,
    crafting_rate,
    fuel_items_per_second,
    mining_rate,
    mining_to_crafting_balance,
)


class FactorioModelTest(unittest.TestCase):
    def test_live_red_science_line_matches_prototype_and_audit(self):
        # Factorio 2.0.77 live spec: assembler-1 speed .5, red science energy 5.
        science = crafting_rate(0.5, 5)
        gear_capacity = crafting_rate(0.5, 0.5)
        self.assertAlmostEqual(0.1, science)
        self.assertAlmostEqual(6, science * 60)
        self.assertEqual("consumer", balance(gear_capacity, science).bottleneck)
        self.assertAlmostEqual(0.2, science * 2)  # iron plates/s through gear recipe

    def test_known_three_drill_two_furnace_bottleneck(self):
        result = mining_to_crafting_balance(
            miners=3,
            mining_speed=0.25,
            mining_time=1,
            furnaces=2,
            crafting_speed=1,
            recipe_energy=3.2,
        )
        self.assertAlmostEqual(0.75, result.source_rate)
        self.assertAlmostEqual(0.625, result.consumer_capacity)
        self.assertAlmostEqual(0.125, result.surplus)
        self.assertEqual("consumer", result.bottleneck)

    def test_three_furnaces_have_headroom(self):
        result = mining_to_crafting_balance(
            miners=3,
            mining_speed=0.25,
            mining_time=1,
            furnaces=3,
            crafting_speed=1,
            recipe_energy=3.2,
        )
        self.assertAlmostEqual(0.75, result.throughput)
        self.assertAlmostEqual(-0.1875, result.surplus)
        self.assertEqual("source", result.bottleneck)

    def test_yellow_belt_capacity_is_fifteen_items_per_second(self):
        self.assertEqual(15, belt_capacity(0.03125))

    def test_coal_burn_rate(self):
        self.assertEqual(0.0375, fuel_items_per_second(150_000, 4_000_000))

    def test_primitives_reject_non_positive_physics(self):
        for call in (
            lambda: mining_rate(0, 1),
            lambda: crafting_rate(1, 0),
            lambda: belt_capacity(-1),
            lambda: fuel_items_per_second(1, 0),
        ):
            with self.assertRaises(ValueError):
                call()

    def test_zero_rate_balance_is_defined(self):
        result = balance(0, 0)
        self.assertEqual(0, result.throughput)
        self.assertEqual(0, result.source_utilization)
        self.assertEqual(0, result.consumer_utilization)
        self.assertEqual("balanced", result.bottleneck)


if __name__ == "__main__":
    unittest.main()
