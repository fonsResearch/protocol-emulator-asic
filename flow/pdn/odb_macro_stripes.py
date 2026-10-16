# SPDX-License-Identifier: MIT
"""OpenROAD (odb) side of Pemu.MacroColumnStripes: run by `openroad -python` through
LibreLane's OdbpyStep after OpenROAD.GeneratePDN.

For every instance whose master name starts with --master-prefix:
  1. collect the macro's Metal4 power-pin rectangles in die coordinates;
  2. collect the tile's VPWR/VGND Metal4 stripe segments (pdngen output);
  3. macro_stripes_geom.plan(): bridge only stripes that lie fully inside a same-polarity
     column, and only over that polarity's pin rectangles (never over Metal4 OBS);
  4. draw the bridge rectangles as STRIPE special wires;
  5. macro_stripes_geom.check() on the resulting shapes: any violation fails the step.

All geometry decisions are in macro_stripes_geom.py (unit-tested without OpenROAD). This file
is only odb glue; it has not been executed outside a LibreLane run.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import click  # noqa: E402
import odb  # noqa: E402
from reader import click_odb  # noqa: E402  (LibreLane scripts/odbpy/reader.py)

import macro_stripes_geom as G  # noqa: E402


def _layer_name(box):
    lay = box.getTechLayer()
    return lay.getName() if lay is not None else None


def _net_segments(net, pol, layer):
    out = []
    for sw in net.getSWires():
        for b in sw.getWires():
            if b.isVia() or _layer_name(b) != layer:
                continue
            out.append(G.Rect(pol, net.getName(), b.xMin(), b.yMin(), b.xMax(), b.yMax()))
    return out


def _macro_columns(inst, pins, layer):
    px, py = inst.getOrigin()
    t = odb.dbTransform(inst.getOrient(), odb.Point(px, py))
    out = []
    for mterm in inst.getMaster().getMTerms():
        name = mterm.getName()
        if name not in pins:
            continue
        for mpin in mterm.getMPins():
            for box in mpin.getGeometry():
                if _layer_name(box) != layer:
                    continue
                a = odb.Point(box.xMin(), box.yMin())
                b = odb.Point(box.xMax(), box.yMax())
                t.apply(a)
                t.apply(b)
                out.append(G.Rect(pins[name], name,
                                  min(a.getX(), b.getX()), min(a.getY(), b.getY()),
                                  max(a.getX(), b.getX()), max(a.getY(), b.getY())))
    return out


@click.command()
@click.option("--layer", default="Metal4", show_default=True)
@click.option("--master-prefix", default="RM_IHPSG13_", show_default=True)
@click.option("--power-net", default="VPWR", show_default=True)
@click.option("--ground-net", default="VGND", show_default=True)
@click.option("--power-pins", default="VDD!,VDDARRAY!", show_default=True)
@click.option("--ground-pins", default="VSS!", show_default=True)
@click.option("--report", "report_path", required=True, type=click.Path())
@click_odb
def main(reader, layer, master_prefix, power_net, ground_net, power_pins, ground_pins, report_path):
    block = reader.block
    lay = reader.tech.findLayer(layer)
    if lay is None:
        raise click.ClickException(f"layer {layer} not found")
    nets = {"P": block.findNet(power_net), "G": block.findNet(ground_net)}
    for pol, n in nets.items():
        if n is None:
            raise click.ClickException(f"supply net for {pol} not found")
    pins = {p: "P" for p in power_pins.split(",")}
    pins.update({p: "G" for p in ground_pins.split(",")})
    names = {"P": power_net, "G": ground_net}

    report = {"macros": [], "violations": []}
    macros = [i for i in block.getInsts() if i.getMaster().getName().startswith(master_prefix)]
    if not macros:
        raise click.ClickException(f"no instance with master prefix {master_prefix}")

    for inst in macros:
        bb = inst.getBBox()
        macro = (bb.xMin(), bb.yMin(), bb.xMax(), bb.yMax())
        cols = _macro_columns(inst, pins, layer)
        segs = _net_segments(nets["P"], "P", layer) + _net_segments(nets["G"], "G", layer)
        plan = G.plan(macro, cols, segs, names)
        for r in plan.rects:
            net = nets[r.pol]
            swires = net.getSWires()
            sw = swires[0] if swires else odb.dbSWire_create(net, "ROUTED")
            odb.dbSBox_create(sw, lay, r.x0, r.y0, r.x1, r.y1, "STRIPE")
        after = _net_segments(nets["P"], "P", layer) + _net_segments(nets["G"], "G", layer)
        viol = G.check(macro, cols, after)
        report["macros"].append({
            "instance": inst.getName(),
            "master": inst.getMaster().getName(),
            "bbox_dbu": macro,
            "orient": str(inst.getOrient()),
            "columns": len(cols),
            "bridged": plan.bridged,
            "skipped": plan.skipped,
            "drawn_rects": [(r.name, r.x0, r.y0, r.x1, r.y1) for r in plan.rects],
            "violations": viol,
        })
        report["violations"] += [f"{inst.getName()}: {v}" for v in viol]
        print(f"[pemu] {inst.getName()}: bridged {len(plan.bridged)} stripes, "
              f"skipped {len(plan.skipped)}, drew {len(plan.rects)} rects, {len(viol)} violations")

    with open(report_path, "w") as f:
        json.dump(report, f, indent=1)
    print(f"%OL_METRIC_I design__macro_stripe_violation__count {len(report['violations'])}")
    print(f"%OL_METRIC_I design__macro_stripe_bridged__count {sum(len(m['bridged']) for m in report['macros'])}")
    if report["violations"]:
        for v in report["violations"]:
            print(f"[pemu] VIOLATION {v}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
