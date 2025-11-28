import zxBuildZon from "../../../build.zig.zon"  with { type: "text" };;
import {ZON} from "zzon";

export function getZxInfo() {
    return ZON.parse(String(zxBuildZon));
}