import type { ComponentMetadata } from "./types";

/**
 * Result of preparing a component for hydration.
 * 
 * Contains all the necessary data to render a React component into its server-rendered container.
 */
export type PreparedComponent = {
  /**
   * The HTML element where the component should be rendered.
   * 
   * This is the DOM node that was server-rendered by ZX with the component's unique ID.
   * The element already exists in the DOM and contains the server-rendered fallback content.
   * React will hydrate this element, replacing its contents with the interactive component.
   * 
   * @example
   * ```tsx
   * // The DOM node corresponds to HTML like:
   * // <div id="zx-dcde04c415da9d1b15ca2690d8b497ae" data-props="...">...</div>
   * 
   * const { domNode } = await prepareComponent(component);
   * createRoot(domNode).render(<Component {...props} />);
   * ```
   */
  domNode: HTMLElement;
  
  /**
   * Component props parsed from the server-rendered HTML.
   * 
   * Props are extracted from the `data-props` attribute (JSON-encoded) on the component's
   * container element. If the component has children from server side then they are automatically converted to
   * `dangerouslySetInnerHTML` for React compatibility.
   * 
   * @example
   * ```tsx
   * // Server-rendered HTML:
   * // <div data-props='{"max_count":10,"label":"Counter"}' data-children="<span>0</span>">...</div>
   * 
   * const { props } = await prepareComponent(component);
   * // props = {
   * //   max_count: 10,
   * //   label: "Counter",
   * //   dangerouslySetInnerHTML: { __html: "<span>0</span>" }
   * // }
   * ```
   */
  props: Record<string, any> & {
    /**
     * React's special prop for setting inner HTML directly.
     * 
     * Automatically added when the component has children in the ZX file. The HTML string
     * is extracted from the `data-children` attribute on the server-rendered element.
     * 
     * @example
     * ```tsx
     * // In ZX file:
     * <MyComponent @rendering={.csr}>
     *   <p>Child content</p>
     * </MyComponent>
     * 
     * // Results in:
     * // props.dangerouslySetInnerHTML = { __html: "<p>Child content</p>" }
     * ```
     */
    dangerouslySetInnerHTML?: { __html: string };
  };
  
  /**
   * The loaded React component function ready to render.
   * 
   * This is the default export from the component module, lazy-loaded via the component's
   * import function. The component is ready to be rendered with React's `createRoot().render()`.
   * 
   * @example
   * ```tsx
   * const { Component, props, domNode } = await prepareComponent(component);
   * 
   * // Component is the default export from the component file:
   * // export default function CounterComponent({ max_count }: { max_count: number }) {
   * //   return <div>Count: {max_count}</div>;
   * // }
   * 
   * createRoot(domNode).render(<Component {...props} />);
   * ```
   */
  Component: (props: any) => React.ReactElement;
};

/**
 * Prepares a client-side component for hydration by locating its DOM container, extracting
 * props and children from server-rendered HTML attributes, and lazy-loading the component module.
 * 
 * This function bridges server-rendered HTML (from ZX's Zig transpiler) and client-side React
 * components. It reads data attributes (`data-props`, `data-children`) from the DOM element
 * with the component's unique ID, then lazy-loads the component module for rendering.
 * 
 * @param component - The component metadata containing ID, import function, and other metadata
 *                    needed to locate and load the component
 * 
 * @returns A Promise that resolves to a `PreparedComponent` object containing the DOM node,
 *          parsed props, and the loaded React component function
 * 
 * @throws {Error} If the component's container element cannot be found in the DOM. This typically
 *                 happens if the component ID doesn't match any element, the script runs before
 *                 the HTML is loaded, or there's a mismatch between server and client metadata
 * 
 * @example
 * ```tsx
 * // Basic usage with React:
 * import { createRoot } from "react-dom/client";
 * import { prepareComponent } from "ziex";
 * import { components } from "@ziex/components";
 * 
 * for (const component of components) {
 *   prepareComponent(component).then(({ domNode, Component, props }) => {
 *     createRoot(domNode).render(<Component {...props} />);
 *   }).catch(console.error);
 * }
 * ```
 * 
 * @example
 * ```tsx
 * // With async/await:
 * async function hydrateComponent(component: ComponentMetadata) {
 *   try {
 *     const { domNode, Component, props } = await prepareComponent(component);
 *     createRoot(domNode).render(<Component {...props} />);
 *   } catch (error) {
 *     console.error(`Failed to hydrate ${component.name}:`, error);
 *   }
 * }
 * 
 * Promise.all(components.map(hydrateComponent));
 * ```
 */
export async function prepareComponent(component: ComponentMetadata): Promise<PreparedComponent> {
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
