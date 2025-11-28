import { getZxInfo } from "./zx" with { type: "macro" };

export const zx: BuildZon = getZxInfo();

type BuildZon = {
    version: string;
    description: string;
    repository: string;
    fingerprint: number;
    minimum_zig_version: string;

};