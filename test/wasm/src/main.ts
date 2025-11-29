import { init } from "ziex/wasm";

const url = new URL("main.wasm", import.meta.url);
init({ url: url.href });

(document.getElementById("input") as HTMLInputElement).oninput = (event: Event) => {
    const idx = window._zx.addEvent(event);

    console.log("idx", idx, event);
    window._zx.exports?.onclick?.(idx);
}