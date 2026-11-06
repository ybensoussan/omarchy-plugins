"""Backend tests: python3 -m unittest discover -s ~/.local/share/display-profiles/tests"""

import copy
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import displayprofiles as dp  # noqa: E402

SHARP = {"name": "eDP-1", "description": "Sharp Corporation LQ150P1JX51 0x002223A0", "make": "Sharp Corporation",
         "model": "LQ150P1JX51", "serial": "0x002223A0", "width": 2496, "height": 1664, "refreshRate": 59.984,
         "x": 0, "y": 0, "scale": 1.6, "transform": 0, "disabled": False, "focused": False,
         "availableModes": ["2496x1664@59.98Hz"], "activeWorkspace": {"id": 7, "name": "ai"}}
DELL_C = {"name": "DP-6", "description": "Dell Inc. DELL P2720DC 7F3SK53", "make": "Dell Inc.",
          "model": "DELL P2720DC", "serial": "7F3SK53", "width": 2560, "height": 1440, "refreshRate": 59.951,
          "x": 1560, "y": 560, "scale": 1, "transform": 0, "disabled": False, "focused": True,
          "availableModes": ["2560x1440@59.95Hz", "1920x1080@60.00Hz"], "activeWorkspace": {"id": 1, "name": "terminal"}}
DELL_D = {"name": "DP-7", "description": "Dell Inc. DELL P2720D 6FCXS03", "make": "Dell Inc.",
          "model": "DELL P2720D", "serial": "6FCXS03", "width": 2560, "height": 1440, "refreshRate": 59.951,
          "x": 4120, "y": 0, "scale": 1, "transform": 3, "disabled": False, "focused": False,
          "availableModes": ["2560x1440@59.95Hz"], "activeWorkspace": {"id": 5, "name": "utilities"}}


class FakeHypr:
    RULE = re.compile(r'output = "([^"]+)", mode = "([^"]+)", position = "(-?\d+)x(-?\d+)", scale = ([\d.]+), transform = (\d)')

    def __init__(self, monitors, clients=(), workspaces=(), reject_explicit=()):
        self.mons = copy.deepcopy(list(monitors))
        self.cls = copy.deepcopy(list(clients))
        self.wss = copy.deepcopy(list(workspaces))
        self.reject_explicit = set(reject_explicit)
        self.scripts, self.reloads = [], 0

    def monitors(self):
        return copy.deepcopy(self.mons)

    def clients(self):
        return copy.deepcopy(self.cls)

    def workspaces(self):
        return copy.deepcopy(self.wss)

    def active_window(self):
        return self.cls[0] if self.cls else None

    def reload(self):
        """Apply generated monitor rules like Hyprland, optionally rejecting explicit modes."""
        self.reloads += 1
        text = dp.ACTIVE_LUA.read_text() if dp.ACTIVE_LUA.exists() else ""
        for output, mode, x, y, scale, transform in self.RULE.findall(text):
            if output in self.reject_explicit and mode != "preferred":
                continue
            for m in self.mons:
                if m["name"] == output:
                    m.update(x=int(x), y=int(y), scale=float(scale), transform=int(transform))

    def config_errors(self):
        return []

    def lua(self, code):
        self.scripts.append(code)
        return "ok"

    def blocks(self):
        known = {"eDP-1": 0, "DP-6": 1, "DP-7": 2}
        return {m["name"]: known.get(m["name"], 3) for m in self.mons if not m.get("disabled")}

    def sleep(self, seconds):
        pass


def v2_monitor(live, workspaces):
    """A monitor as stored by the v2 format: an ordered list of workspace names, no slots."""
    monitor = dp.monitor_from_live(live)
    del monitor["slots"]
    monitor["workspaces"] = list(workspaces)
    return monitor


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        dp.HYPR = root / "hypr"
        dp.DATA = dp.HYPR / "display-profiles"
        dp.PROFILES = dp.DATA / "profiles"
        dp.CATALOG = dp.DATA / "catalog.json"
        dp.STATE_DIR = root / "state"
        dp.STATE = dp.STATE_DIR / "state.json"
        dp.LOCK = dp.STATE_DIR / "lock"
        dp.ACTIVE_LUA = dp.HYPR / "workspace-profile.lua"
        dp.ORDER_JSON = dp.HYPR / "workspace-order.json"
        dp.MENU = root / "menu.jsonc"
        dp.LEGACY_PROFILES = dp.HYPR / "workspace-profiles"
        dp.MONITORS_LUA = dp.HYPR / "monitors.lua"
        dp.OMARCHY_TOGGLES = root / "state/omarchy/toggles/hypr"
        dp.OMARCHY_BLOCKS = root / "state/omarchy/monitor-workspaces"
        self.catalog = dp.load_catalog()

    def tearDown(self):
        self.tmp.cleanup()

    def desk(self, **overrides):
        live = [SHARP, DELL_C, DELL_D]
        profile = {
            "name": "desk",
            "monitors": [
                v2_monitor(dict(SHARP, x=0, y=560), ["ai"]),
                v2_monitor(DELL_C, ["terminal", "browser", "editor", "remote"]),
                v2_monitor(DELL_D, ["utilities", "outlook", "teams"]),
            ],
        }
        profile.update(overrides)
        return dp.normalize_profile(profile, self.catalog), live


class MatchingTests(Base):
    def test_resolves_by_edid_even_when_connectors_change(self):
        profile, live = self.desk()
        swapped = [dict(SHARP), dict(DELL_C, name="DP-9"), dict(DELL_D, name="DP-8")]
        self.assertEqual(dp.resolve(profile, swapped), ["eDP-1", "DP-9", "DP-8"])

    def test_identical_model_different_serial_does_not_match(self):
        profile, _ = self.desk()
        other = dict(DELL_D, serial="ZZZ", description="Dell Inc. DELL P2720D ZZZ")
        self.assertEqual(dp.resolve(profile, [SHARP, DELL_C, other])[2], None)

    def test_each_live_monitor_used_once_no_ghosts(self):
        profile, _ = self.desk()
        dup = copy.deepcopy(profile)
        dup["monitors"].append(dict(copy.deepcopy(profile["monitors"][1]), match=dict(
            profile["monitors"][1]["match"], serial="", description="")))
        matched = dp.resolve(dup, [SHARP, DELL_C, DELL_D])
        self.assertEqual(matched.count("DP-6"), 1)

    def test_detect_prefers_most_specific_complete_profile(self):
        desk, live = self.desk()
        laptop = dp.normalize_profile({"name": "laptop", "monitors": [dp.monitor_from_live(SHARP)]}, self.catalog)
        self.assertEqual(dp.detect([laptop, desk], live), "desk")
        self.assertEqual(dp.detect([laptop, desk], [SHARP]), "laptop")
        self.assertIsNone(dp.detect([desk], [DELL_C]))


class ProfileTests(Base):
    def test_overlap_rejected(self):
        profile, _ = self.desk()
        profile["monitors"][2]["x"] = 1600
        with self.assertRaises(dp.UserError):
            dp.normalize_profile(profile, self.catalog)

    def test_rotated_logical_size_used_for_overlap(self):
        profile, _ = self.desk()
        # DP-7 is portrait (1440 wide); placing it 1440 right of DP-6's end must not overlap
        profile["monitors"][2]["x"] = 4120
        dp.normalize_profile(profile, self.catalog)

    def test_v2_workspace_lists_become_slots_and_keep_the_bar(self):
        profile, _ = self.desk()
        slots = profile["monitors"][1]["slots"]
        self.assertEqual(len(slots), 10)
        self.assertEqual([s["name"] for s in slots[:4]], ["terminal", "browser", "editor", "remote"])
        self.assertEqual([s["hidden"] for s in slots], [False] * 4 + [True] * 6)
        self.assertNotIn("parked", profile)
        self.assertNotIn("numbers", profile)

    def test_new_monitor_shows_first_five_slots(self):
        slots = dp.monitor_from_live(SHARP)["slots"]
        self.assertEqual([s["hidden"] for s in slots], [False] * 5 + [True] * 5)
        self.assertTrue(all(s["name"] == "" for s in slots))

    def test_duplicate_name_rejected_when_saving_and_dropped_when_loading(self):
        doc = {"name": "x", "monitors": [v2_monitor(SHARP, ["ai"]),
                                         v2_monitor(DELL_C, ["AI", "web"])]}
        with self.assertRaises(dp.UserError):
            dp.normalize_profile(copy.deepcopy(doc), self.catalog)
        loose = dp.normalize_profile(copy.deepcopy(doc), self.catalog, strict=False)
        self.assertEqual([s["name"] for s in loose["monitors"][1]["slots"][:2]], ["", "web"])

    def test_slot_names_need_not_be_in_the_catalog(self):
        doc = {"name": "x", "monitors": [dict(dp.monitor_from_live(SHARP),
                                              slots=[{"name": "music", "hidden": False}])]}
        profile = dp.normalize_profile(doc, self.catalog)
        self.assertEqual(profile["monitors"][0]["slots"][0], {"name": "music", "hidden": False})
        self.assertEqual(len(profile["monitors"][0]["slots"]), 10)

    def test_positions_translated_to_origin(self):
        profile, _ = self.desk()
        for monitor in profile["monitors"]:
            monitor["x"] += 500
        profile = dp.normalize_profile(profile, self.catalog)
        self.assertEqual(min(m["x"] for m in profile["monitors"]), 0)


class PlanTests(Base):
    BLOCKS = {"eDP-1": 0, "DP-6": 1, "DP-7": 2}

    def test_lua_uses_connector_and_exact_mode(self):
        profile, live = self.desk()
        lua = dp.render_lua(dp.plan(profile, self.catalog, live, self.BLOCKS))
        self.assertIn('-- workspace-profiles.desk', lua)
        # native modes use "preferred" (explicit native modes make some panels fall back to auto placement)
        self.assertIn('hl.monitor({ output = "DP-6", mode = "preferred", position = "1560x560", scale = 1, transform = 0 })', lua)
        self.assertIn('if not omarchy_internal_off() then hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x560", scale = 1.6, transform = 0 }) end', lua)
        self.assertIn('hl.workspace_rule({ workspace = "1", default_name = "ai", monitor = "eDP-1", persistent = true })', lua)
        self.assertIn('hl.workspace_rule({ workspace = "11", default_name = "terminal", monitor = "DP-6", persistent = true })', lua)
        self.assertIn('hl.workspace_rule({ workspace = "23", default_name = "teams", monitor = "DP-7", persistent = true })', lua)
        self.assertNotIn("references", lua)
        self.assertIn('o.window("^zen$", { workspace = "12" })', lua)

    def test_hidden_named_slot_keeps_its_name_but_is_not_persistent(self):
        profile, live = self.desk()
        profile["monitors"][1]["slots"][1]["hidden"] = True
        lua = dp.render_lua(dp.plan(profile, self.catalog, live, self.BLOCKS))
        self.assertIn('hl.workspace_rule({ workspace = "12", default_name = "browser", monitor = "DP-6" })', lua)
        self.assertIn('o.window("^zen$", { workspace = "12" })', lua)

    def test_no_workspace_rules_without_a_block(self):
        profile, live = self.desk()
        the_plan = dp.plan(profile, self.catalog, live, {"eDP-1": 0})
        lua = dp.render_lua(the_plan)
        self.assertIn('default_name = "ai"', lua)
        self.assertNotIn('default_name = "terminal"', lua)
        self.assertFalse(any(a["name"] == "browser" for a in the_plan["apps"]))

    def test_non_native_mode_is_explicit(self):
        profile, live = self.desk()
        profile["monitors"][1].update(mode="1920x1080@60.00Hz", width=1920, height=1080)
        profile = dp.normalize_profile(profile, self.catalog)
        lua = dp.render_lua(dp.plan(profile, self.catalog, live, self.BLOCKS))
        self.assertIn('output = "DP-6", mode = "1920x1080@60.00Hz"', lua)

    def test_order_document_lists_slots_per_monitor_left_to_right(self):
        profile, live = self.desk()
        order = dp.order_document(dp.plan(profile, self.catalog, live, self.BLOCKS))
        self.assertEqual(order["version"], 3)
        self.assertEqual([m["output"] for m in order["monitors"]], ["eDP-1", "DP-6", "DP-7"])
        dp6 = order["monitors"][1]
        self.assertEqual(dp6["block"], 1)
        self.assertEqual(dp6["slots"][0], {"slot": 1, "name": "terminal", "hidden": False, "id": 11})
        self.assertEqual(dp6["slots"][9], {"slot": 10, "name": "", "hidden": True, "id": 20})
        self.assertEqual(len(order["assignments"]), 30)

    def test_missing_monitor_gets_no_workspaces(self):
        profile, _ = self.desk()
        the_plan = dp.plan(profile, self.catalog, [SHARP, DELL_C], self.BLOCKS)
        self.assertFalse(any(t["name"] == "outlook" for t in the_plan["targets"]))
        self.assertEqual([m["output"] for m in the_plan["monitors"]], ["eDP-1", "DP-6"])

    def test_disabled_monitor(self):
        profile, live = self.desk()
        profile["monitors"][0]["enabled"] = False
        the_plan = dp.plan(profile, self.catalog, live, self.BLOCKS)
        self.assertIn('hl.monitor({ output = "eDP-1", disabled = true })', dp.render_lua(the_plan))
        self.assertFalse(any(t["name"] == "ai" for t in the_plan["targets"]))


class OmarchyIntegrationTests(Base):
    def test_monitors_lua_block_is_managed(self):
        dp.write_text(dp.MONITORS_LUA, 'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })\n')
        profile, live = self.desk()
        dp.sync_omarchy_internal(dp.plan(profile, self.catalog, live))
        text = dp.MONITORS_LUA.read_text()
        self.assertIn('hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x560", scale = 1.6 })', text)
        self.assertTrue(text.startswith('hl.monitor({ output = ""'))
        dp.sync_omarchy_internal(dp.plan(profile, self.catalog, live))
        self.assertEqual(dp.MONITORS_LUA.read_text().count(dp.MANAGED_BEGIN), 1)
        external_only = dp.normalize_profile({"name": "ext", "monitors": [dp.monitor_from_live(DELL_C)]}, self.catalog)
        dp.sync_omarchy_internal(dp.plan(external_only, self.catalog, live))
        self.assertNotIn(dp.MANAGED_BEGIN, dp.MONITORS_LUA.read_text())

    def test_disabled_panel_uses_omarchy_toggle_and_is_cleaned_up(self):
        profile, live = self.desk()
        profile["monitors"][0]["enabled"] = False
        dp.sync_omarchy_internal(dp.plan(profile, self.catalog, live))
        flag = dp.OMARCHY_TOGGLES / "internal-monitor-disable.lua"
        self.assertIn(dp.OWN_MARKER, flag.read_text())
        self.assertFalse(dp.internal_blocked_by_omarchy())
        profile["monitors"][0]["enabled"] = True
        dp.sync_omarchy_internal(dp.plan(profile, self.catalog, live))
        self.assertFalse(flag.exists())

    def test_clamshell_blocks_panel_and_moves_its_workspaces(self):
        dp.write_text(dp.OMARCHY_TOGGLES / "internal-monitor-clamshell.lua", 'hl.monitor({ output = "eDP-1", disabled = true })\n')
        profile, live = self.desk()
        the_plan = dp.plan(profile, self.catalog, live, PlanTests.BLOCKS)
        self.assertNotIn("eDP-1", the_plan["expected"])
        self.assertFalse(any(t["name"] == "ai" for t in the_plan["targets"]))
        # a user's own manual toggle is never removed by us
        dp.write_text(dp.OMARCHY_TOGGLES / "internal-monitor-disable.lua", "user\n")
        dp.sync_omarchy_internal(the_plan)
        self.assertTrue((dp.OMARCHY_TOGGLES / "internal-monitor-disable.lua").exists())


class WindowMoveTests(Base):
    def test_windows_follow_workspace_names_and_orphans_use_app_rules(self):
        profile, live = self.desk()
        the_plan = dp.plan(profile, self.catalog, live, PlanTests.BLOCKS)
        clients = [
            {"address": "0x1", "class": "chrome-faolnafnngnfdaknnbpnkhgohbobgegn-Default", "workspace": {"id": 1, "name": "ai"}},
            {"address": "0x2", "class": "foot", "workspace": {"id": 20, "name": "utilities"}},
            {"address": "0x3", "class": "org.remmina.Remmina", "workspace": {"id": -1340, "name": "rem"}},
            {"address": "0x4", "class": "foot", "workspace": {"id": 12, "name": "12"}},
            {"address": "0x5", "class": "foot", "workspace": {"id": -98, "name": "special:scratchpad"}},
            {"address": "0x6", "class": "zen", "workspace": {"id": 12, "name": "browser"}},
        ]
        moves = {m["address"]: m["id"] for m in dp.window_moves(the_plan, clients, [])}
        self.assertEqual(moves, {"0x2": 21, "0x3": 14})

    def test_windows_on_old_global_numbers_move_into_the_block(self):
        profile, live = self.desk()
        the_plan = dp.plan(profile, self.catalog, live, PlanTests.BLOCKS)
        clients = [{"address": "0xa", "class": "x", "workspace": {"id": 1, "name": "terminal"}}]
        self.assertEqual(dp.window_moves(the_plan, clients, []), [{"address": "0xa", "id": 11, "class": "x"}])

    def test_runtime_script_renames_and_shows_own_workspaces(self):
        profile, live = self.desk()
        the_plan = dp.plan(profile, self.catalog, live, PlanTests.BLOCKS)
        live = [dict(SHARP, activeWorkspace={"id": 1, "name": "ai"}), DELL_C, dict(DELL_D, activeWorkspace={"id": 26, "name": "26"})]
        script = dp.runtime_script(the_plan, [{"address": "0x2", "id": 21, "class": "foot"}], live, "0x9")
        self.assertIn('window = "address:0x2", workspace = "21", follow = false', script)
        self.assertIn('hl.dsp.workspace.rename({ workspace = 11, name = "terminal" })', script)
        self.assertIn('hl.dsp.workspace.rename({ workspace = 15, name = "15" })', script)
        # eDP-1 shows its visible slot 1; DP-6 shows 1 (the laptop's block); DP-7 shows its hidden slot 6.
        self.assertNotIn('show(1, "eDP-1")', script)
        self.assertIn('show(1, "DP-6")', script)
        self.assertIn('show(1, "DP-7")', script)
        self.assertIn('hl.dsp.focus({ window = "address:0x9" })', script)


class ApplyTests(Base):
    def test_apply_writes_files_and_state(self):
        profile, live = self.desk()
        hypr = FakeHypr(live, [{"address": "0x2", "class": "foot", "workspace": {"id": 30, "name": "utilities"}}])
        result = dp.apply_profile(profile, hypr, manual=True)
        self.assertEqual(result["moved"], 1)
        self.assertEqual(hypr.reloads, 1)
        self.assertTrue(dp.ACTIVE_LUA.read_text().startswith("-- Generated"))
        order = json.loads(dp.ORDER_JSON.read_text())
        self.assertEqual(order["profile"], "desk")
        self.assertEqual(next(a for a in order["assignments"] if a["name"] == "utilities")["id"], 21)
        self.assertEqual(dp.load_state()["active"], "desk")

    def test_new_block_after_reload_regenerates_rules(self):
        profile, live = self.desk()
        hypr = FakeHypr(live)
        calls = {"n": 0}
        real = hypr.blocks

        def blocks():
            calls["n"] += 1
            result = real()
            if calls["n"] == 1:
                result.pop("DP-7")  # not assigned a block before the reload
            return result
        hypr.blocks = blocks
        dp.apply_profile(profile, hypr)
        self.assertEqual(hypr.reloads, 2)
        self.assertIn('workspace = "21", default_name = "utilities"', dp.ACTIVE_LUA.read_text())

    def test_rejected_rule_is_retried_with_preferred(self):
        profile, live = self.desk()
        profile["monitors"][1].update(mode="1920x1080@60.00Hz", width=1920, height=1080, x=1560, y=700)
        profile["monitors"][2]["x"] = 1560 + 1920
        profile = dp.normalize_profile(profile, self.catalog)
        hypr = FakeHypr(live, reject_explicit={"DP-6"})
        result = dp.apply_profile(profile, hypr)
        self.assertEqual(hypr.reloads, 2)
        self.assertEqual(result["warnings"], [])
        self.assertIn('output = "DP-6", mode = "preferred"', dp.ACTIVE_LUA.read_text())

    def test_sync_switches_on_hotplug_and_keeps_manual(self):
        profile, live = self.desk()
        dp.write_json(dp.profile_path("desk"), profile)
        laptop = dp.normalize_profile({"name": "laptop", "monitors": [dp.monitor_from_live(SHARP)]}, self.catalog)
        dp.write_json(dp.profile_path("laptop"), laptop)
        hypr = FakeHypr(live)
        self.assertEqual(dp.sync(hypr, "t")["applied"], "desk")
        self.assertIn("skipped", dp.sync(hypr, "t"))
        hypr.mons = [SHARP]
        self.assertEqual(dp.sync(hypr, "t")["applied"], "laptop")
        dp.save_state(active="desk", manual=True)
        self.assertIn("skipped", dp.sync(hypr, "t"))

    def test_catalog_rename_propagates(self):
        profile, live = self.desk()
        dp.write_json(dp.profile_path("desk"), profile)
        catalog = copy.deepcopy(self.catalog)
        catalog["workspaces"][6]["name"] = "llm"
        catalog["renames"] = {"ai": "llm"}
        dp.cmd_catalog_save(catalog, FakeHypr(live))
        saved = dp.load_profile("desk")
        self.assertEqual(saved["monitors"][0]["slots"][0]["name"], "llm")


class MenuAndSwitchTests(Base):
    def test_menu_lists_visible_slots_of_every_monitor(self):
        dp.write_text(dp.MENU, "{\n"
                      '  "trigger.workspaces": {"label":"Workspaces"},\n'
                      '  "trigger.workspaces.old": {"label":"Old"},\n'
                      '  "trigger.move-window-workspace": {"label":"Move"},\n'
                      '  "trigger.move-window-workspace.old": {"label":"Old"},\n'
                      '  "trigger.move-window-workspace.scratchpad": {"label":"Scratchpad"},\n'
                      "}\n")
        profile, live = self.desk()
        profile["monitors"][1]["slots"][1]["hidden"] = True
        dp.sync_menu(dp.plan(profile, self.catalog, live, PlanTests.BLOCKS), [])
        text = dp.MENU.read_text()
        self.assertNotIn(".old", text)
        self.assertIn('"trigger.workspaces.dp-6-1": {"icon": "󰙀", "label": "Terminal · Middle", '
                      '"description": "Super+1 on DELL P2720DC (DP-6)", "action": "omarchy-workspace-switch DP-6:1"}', text)
        self.assertIn('"label": "Ai · Laptop"', text)
        self.assertIn('"label": "Teams · Right"', text)
        self.assertIn('"trigger.move-window-workspace.dp-7-3": ', text)
        self.assertIn('"action": "omarchy-workspace-move-window DP-7:3"', text)
        self.assertNotIn("DP-6:2", text)  # hidden
        self.assertIn('"trigger.move-window-workspace.scratchpad"', text)
        # empty blocks are re-inserted under their parent
        profile2 = dp.normalize_profile({"name": "x", "monitors": [dict(dp.monitor_from_live(SHARP), slots=[
            {"name": "", "hidden": True}] * 10)]}, self.catalog)
        dp.sync_menu(dp.plan(profile2, self.catalog, [SHARP], PlanTests.BLOCKS), [])
        dp.sync_menu(dp.plan(profile, self.catalog, live, PlanTests.BLOCKS), [])
        self.assertIn("DP-6:1", dp.MENU.read_text())

    def test_identical_monitors_are_told_apart_by_position(self):
        dp.write_text(dp.MENU, '{\n  "trigger.workspaces": {"label":"Workspaces"},\n}\n')
        twin = dict(DELL_D, name="DP-8", serial="ZZZ", description="Dell Inc. DELL P2720D ZZZ", x=5560)
        profile = dp.normalize_profile({"name": "x", "monitors": [
            v2_monitor(DELL_D, ["slack"]), v2_monitor(twin, ["mail"])]}, self.catalog)
        dp.sync_menu(dp.plan(profile, self.catalog, [DELL_D, twin], {"DP-7": 2, "DP-8": 3}), [])
        text = dp.MENU.read_text()
        self.assertIn('"label": "Slack · Left"', text)
        self.assertIn('"label": "Mail · Right"', text)

    def test_resolve_by_reference_name_or_id(self):
        profile, live = self.desk()
        dp.write_json(dp.ORDER_JSON, dp.order_document(dp.plan(profile, self.catalog, live, PlanTests.BLOCKS)))
        self.assertEqual(dp.resolve_workspace("DP-7:3"), ("DP-7", 3))
        self.assertEqual(dp.resolve_workspace("Terminal"), ("DP-6", 1))
        self.assertEqual(dp.resolve_workspace("22"), ("DP-7", 2))
        self.assertIsNone(dp.resolve_workspace("nope"))

    def test_send_creates_the_slot_on_its_own_monitor(self):
        hypr = FakeHypr([SHARP])
        hypr.lua = lambda code: (hypr.scripts.append(code), "13")[1]
        self.assertEqual(dp.cmd_switch("DP-6:3", hypr, send=True)["workspace"], "13")
        script = hypr.scripts[-1]
        self.assertIn('o.workspaces.workspace_id(monitor, 3)', script)
        self.assertIn('if not hl.get_workspace(id) then o.workspaces.focus(3, "DP-6")() end', script)
        self.assertIn("follow = true", script)
        dp.cmd_switch("DP-6:3", hypr)
        self.assertIn('o.workspaces.focus(3, "DP-6")()', hypr.scripts[-1])


class LegacyTests(Base):
    def test_migrates_names_numbering_and_order(self):
        dp.LEGACY_PROFILES.mkdir(parents=True)
        dp.write_json(dp.LEGACY_PROFILES / "office.json", {
            "assignments": [{"workspace": "1", "monitor": "desc:HP Inc. HP E27 G5 CNC3192C8D"},
                            {"workspace": "4", "monitor": "desc:HP Inc. HP E27 G5 CNC3200QDS"},
                            {"workspace": "5", "monitor": ""},
                            {"workspace": "6", "monitor": "desc:" + SHARP["description"]}],
            "layout": [{"monitor": "desc:" + SHARP["description"], "x": 3840, "y": 0, "width": 2496, "height": 1664,
                        "scale": 1.6, "transform": 0, "refreshRate": 59.984},
                       {"monitor": "desc:HP Inc. HP E27 G5 CNC3200QDS", "x": 0, "y": 0, "width": 1920, "height": 1080,
                        "scale": 1, "transform": 0, "refreshRate": 60},
                       {"monitor": "desc:HP Inc. HP E27 G5 CNC3192C8D", "x": 1920, "y": 0, "width": 1920,
                        "height": 1080, "scale": 1, "transform": 0, "refreshRate": 60}],
            "numbering": {"1": 1, "2": 2, "3": 3, "4": 6, "5": 10, "6": 5, "7": 4, "8": 7, "9": 8, "10": 9},
            "names": {"1": "terminal", "2": "browser", "3": "editor", "4": "ai", "5": "references", "6": "utilities",
                      "7": "remote", "8": "outlook", "9": "teams", "10": "10"}})
        [office] = dp.migrate_legacy([SHARP], self.catalog)
        self.assertEqual(office["monitors"][0]["mode"], "2496x1664@59.98Hz")
        self.assertEqual(office["monitors"][0]["match"]["serial"], "0x002223A0")
        self.assertEqual(office["monitors"][1]["match"]["description"], "HP Inc. HP E27 G5 CNC3200QDS")
        self.assertEqual(office["monitors"][1]["slots"][0], {"name": "ai", "hidden": False})


class HelperTests(Base):
    def test_clean_scales(self):
        scales = {s["scale"] for s in dp.clean_scales(2496, 1664)}
        self.assertIn(1.6, scales)
        self.assertIn(1.0, scales)
        self.assertNotIn(1.5, scales)

    def test_lua_str_escapes(self):
        self.assertEqual(dp.lua_str('a"b\\c'), '"a\\"b\\\\c"')

    def test_labels(self):
        self.assertEqual(dp.short_label(SHARP), "Built-in display")
        self.assertEqual(dp.short_label(DELL_C), "DELL P2720DC")
        self.assertEqual(dp.short_label({"name": "DP-1", "make": "HP Inc.", "model": "E27 G5"}), "HP E27 G5")


if __name__ == "__main__":
    unittest.main()
