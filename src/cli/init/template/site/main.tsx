import { createRoot } from "react-dom/client";
import { prepareComponent } from "ziex";

/** The components array is generated once `zig build` or `zx dev` or `zx serve` is run. **/
import { components } from "@ziex/components";

for (const component of components)
  prepareComponent(component).then(({ domNode, Component, props }) =>
    createRoot(domNode).render(<Component {...props} />),
  );
