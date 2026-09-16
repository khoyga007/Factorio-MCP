import io
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from survey import survey


class SurveyTest(unittest.TestCase):
    def test_reads_every_page_and_summarizes_issues(self):
        base = {"ok": True, "entities_total": 2, "tick": 100,
                "resources": [{"name": "iron-ore", "amount": 12}],
                "treasury": {"contents": []}}
        pages = [
            {**base, "entities_next_offset": 64, "entities": [
                {"name": "transport-belt", "type": "transport-belt", "x": 1, "y": 2}]},
            {**base, "entities_next_offset": None, "entities": [
                {"name": "electric-mining-drill", "type": "mining-drill",
                 "x": 3, "y": 4, "status_name": "no_power"}]},
        ]
        output = io.StringIO()
        with patch("survey.request", side_effect=pages) as calls, redirect_stdout(output):
            self.assertEqual(0, survey(0, 0))
        self.assertEqual(2, calls.call_count)
        self.assertIn("entities=2/2 pages=2", output.getvalue())
        self.assertIn("electric-mining-drill (3,4) no_power", output.getvalue())
        self.assertIn("'iron-ore': 12", output.getvalue())


if __name__ == "__main__":
    unittest.main()
