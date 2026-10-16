# SPDX-License-Identifier: MIT
"""LibreLane plugin: Pemu.MacroColumnStripes.

Discovery (LibreLane 3.1.0.dev3, librelane/plugins.py): any importable top-level module named
`librelane_plugin_*` is imported at start-up. `tt_tool.py --harden` runs `python -m librelane`
from the repository root (also inside the LibreLane container, which mounts the working
directory and sets it as the container working directory), so this file is importable there.
That is read from source, not yet observed in a CI run.

Inserted after OpenROAD.GeneratePDN by `meta.substituting_steps` in src/config.json.
The geometry lives in flow/pdn/macro_stripes_geom.py (unit tests: flow/pdn/test_macro_stripes.py).
"""
import os
from typing import List

from librelane.config import Variable
from librelane.steps import Step
from librelane.steps.odb import OdbpyStep

HERE = os.path.dirname(os.path.abspath(__file__))


@Step.factory.register()
class MacroColumnStripes(OdbpyStep):
    """Bridge the tile's Metal4 VPWR/VGND stripes onto the IHP SRAM macro's Metal4 power
    columns, only where a stripe lies fully inside a column of the same polarity, and fail
    if any supply shape over the macro violates the column/polarity property."""

    id = "Pemu.MacroColumnStripes"
    name = "Bridge PDN stripes onto aligned SRAM power columns"

    config_vars = [
        Variable(
            "PEMU_STRIPE_LAYER", str, "Layer of the tile's vertical PDN stripes and the macro power columns.",
            default="Metal4",
        ),
        Variable(
            "PEMU_STRIPE_MASTER_PREFIX", str, "Master-name prefix of the macros to bridge.",
            default="RM_IHPSG13_",
        ),
        Variable("PEMU_STRIPE_POWER_NET", str, "Tile power net of the stripes.", default="VPWR"),
        Variable("PEMU_STRIPE_GROUND_NET", str, "Tile ground net of the stripes.", default="VGND"),
        Variable(
            "PEMU_STRIPE_POWER_PINS", str, "Comma-separated macro power pins tied to VDD_NET.",
            default="VDD!,VDDARRAY!",
        ),
        Variable(
            "PEMU_STRIPE_GROUND_PINS", str, "Comma-separated macro ground pins tied to GND_NET.",
            default="VSS!",
        ),
    ]

    def get_script_path(self) -> str:
        return os.path.join(HERE, "flow", "pdn", "odb_macro_stripes.py")

    def get_command(self) -> List[str]:
        return super().get_command() + [
            "--layer", self.config["PEMU_STRIPE_LAYER"],
            "--master-prefix", self.config["PEMU_STRIPE_MASTER_PREFIX"],
            "--power-net", self.config["PEMU_STRIPE_POWER_NET"],
            "--ground-net", self.config["PEMU_STRIPE_GROUND_NET"],
            "--power-pins", self.config["PEMU_STRIPE_POWER_PINS"],
            "--ground-pins", self.config["PEMU_STRIPE_GROUND_PINS"],
            "--report", os.path.join(self.step_dir, "macro_stripes.json"),
        ]
