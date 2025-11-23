/**
 * The metadata for a component that was used within ZX file
 */
export type ComponentMetadata = {
  /**
   * The name of the component, this is what name was used in the component declaration
   * e.g. <CounterComponent />
   */
  name: string;
  /**
   * The path to the component, this is the path to the component file
   * e.g. ./components/CounterComponent.tsx
   */
  path: string;
  /**
   * The id of the component, this is a unique identifier for the component and an additinal index in case the same component is used multiple times
   * e.g. zx-1234567890 or zx-1234567890-1
   */
  id: string;
  /**
   * The import function for the component, this is the function that will be used to import the component
   * e.g. () => import('./components/CounterComponent.tsx')
   */
  import: () => Promise<(props: unknown) => React.ReactElement>;
};
