import os
import unittest

from factorio_model import belt_capacity_from_spec, mining_to_crafting_from_spec
from spec_loader import load_spec

SAMPLE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "spec_sample.json")


class ModelFromSpecTest(unittest.TestCase):
    def setUp(self):
        self.spec = load_spec(SAMPLE)

    def test_three_drill_two_furnace_matches_hand_checked(self):
        # Same numbers as FactorioModelTest.test_known_three_drill_two_furnace_bottleneck.
        result = mining_to_crafting_from_spec(
            self.spec,
            miner="burner-mining-drill",
            recipe="iron-plate",
            furnace="stone-furnace",
            miners=3,
            furnaces=2,
        )
        self.assertAlmostEqual(0.75, result.source_rate)
        self.assertAlmostEqual(0.625, result.consumer_capacity)
        self.assertAlmostEqual(0.125, result.surplus)
        self.assertEqual("consumer", result.bottleneck)

    def test_belt_capacity_from_spec(self):
        self.assertEqual(15, belt_capacity_from_spec(self.spec, "transport-belt"))

    def test_missing_field_raises_named_error(self):
        with self.assertRaises(ValueError) as ctx:
            mining_to_crafting_from_spec(
                self.spec,
                miner="assembler1",  # fixture has no mining_speed
                recipe="iron-plate",
                furnace="stone-furnace",
                miners=3,
                furnaces=2,
            )
        self.assertIn("assembler1.mining_speed", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
