import React, { useState } from "react";

export default function Page() {
    const [count, setCount] = useState(0);

    return (
        <main>
            <button onClick={() => setCount(count + 1)}>Increment</button>
            <button onClick={() => setCount(count - 1)}>Decrement</button>
            <p>{count}</p>
        </main>
    );
}