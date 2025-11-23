import type { ComponentMetadata } from "./types";

/**
 * Prepare a component for rendering
 * @param component - The component to prepare
 * @returns The component, props, and DOM node
 */
export async function prepareComponent(component: ComponentMetadata) {
  const domNode = document.getElementById(component.id);
  if (!domNode) throw new Error(`Root element ${component.id} not found`);

  const props = JSON.parse(domNode.getAttribute("data-props") || "{}");
  const htmlChildren = domNode.getAttribute("data-children") ?? undefined;

  if (htmlChildren) {
    props.dangerouslySetInnerHTML = { __html: htmlChildren };
  }

  const Component = await component.import();
  return { domNode, props, Component };
}
