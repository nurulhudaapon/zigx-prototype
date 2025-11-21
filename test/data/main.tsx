import React from 'react';
import { createRoot } from 'react-dom/client';

const components = [
  {
    "type": "csr",
    "id": "zx-dcde04c415da9d1b15ca2690d8b497ae",
    "name": "CounterComponent",
    "path": "component/csr_react.tsx",
    "import": async () => (await import('./component/csr_react.tsx')).default
  },
  {
    "type": "csr",
    "id": "zx-dcde04c415da9d1b15ca2690d8b497ae",
    "name": "CounterComponent",
    "path": "component/csr_react.tsx",
    "import": async () => (await import('./component/csr_react.tsx')).default
  },
  {
    "type": "csr",
    "id": "zx-817a92c3e8f78257d9993f89eb0cb6bb",
    "name": "AnotherComponent",
    "path": "component/csr_react_multiple.tsx",
    "import": async () => (await import('./component/csr_react_multiple.tsx')).default
  }
] as unknown as ComponentMetadata[];

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
