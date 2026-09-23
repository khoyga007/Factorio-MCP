import unittest

from contract_check import (
    check,
    client_actions,
    client_commands,
    handlers_in_lua,
    load_actions,
)


class ContractTest(unittest.TestCase):
    def test_three_sources_agree(self):
        self.assertEqual([], check())

    def test_known_action_count_is_twenty_seven(self):
        self.assertEqual(27, len(load_actions()))

    def test_lua_handlers_count_is_twenty_seven(self):
        self.assertEqual(27, len(handlers_in_lua()))

    def test_client_action_count_is_twenty_seven(self):
        self.assertEqual(27, len(client_actions()))

    def test_client_commands_match_declared_clients(self):
        actions = load_actions()
        declared = {a.get("client", name) for name, a in actions.items()}
        self.assertEqual(client_commands(), declared)

    def test_name_drift_is_declared_explicitly(self):
        # Client command names with dashes differ from bridge action names.
        actions = load_actions()
        self.assertEqual("treasury", actions["set_treasury"]["client"])
        self.assertEqual("set-recipe", actions["set_recipe"]["client"])


if __name__ == "__main__":
    unittest.main()
