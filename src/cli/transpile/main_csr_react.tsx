import React from 'react';
import { createRoot } from 'react-dom/client';

const components = `{[ZX_COMPONENTS]s}` as unknown as ComponentMetadata[];

for (const component of components) renderComponent(component).catch(console.error);

async function renderComponent(component: ComponentMetadata) {
  const domNode = document.getElementById(component.id);
  if (!domNode) throw new Error(`Root element ${component.id} not found`);
  const props = JSON.parse(domNode.getAttribute('data-props') || '{}');
  props.html = domNode.getAttribute('data-children') ?? undefined;

  const ImportedComponent = await component.import();
  createRoot(domNode).render(<ImportedComponent {...props} />);
}

type ComponentMetadata = {
  name: string;
  path: string;
  id: string;
  import: () => Promise<(props: unknown) => React.ReactElement>;
}
