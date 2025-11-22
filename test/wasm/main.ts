import { ZigJS } from "jsz/js/src";

const jsz = new ZigJS();
const importObject = {
  module: {},
  env: {},
  ...jsz.importObject(),
};

const url = new URL("main.wasm", import.meta.url);
fetch(url.href)
  .then((response) => response.arrayBuffer())
  .then((bytes) => WebAssembly.instantiate(bytes, importObject))
  .then(({ instance }) => {
    const main = instance.exports.main as () => void;
    jsz.memory = instance.exports.memory as WebAssembly.Memory;
    main();
  });
