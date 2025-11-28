import type { ComponentMetadata } from "./types";

export type PreparedComponent = {

};

export async function prepareComponent(component: ComponentMetadata): Promise<PreparedComponent> {
  throw new Error("Not implemented");
}

export function filterComponents(components: ComponentMetadata[]): ComponentMetadata[] {
  throw new Error("Not implemented");
}