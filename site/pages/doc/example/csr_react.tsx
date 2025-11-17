import React, { useState } from "react";

export default function Page(props: { html: string, visit_count: number }) {
    const [visit_count, setVisitCount] = useState(props.visit_count);

    return (
        <main>
            <button onClick={() => setVisitCount(visit_count + 1)}>Increment</button>
            <button onClick={() => setVisitCount(visit_count - 1)}>Decrement</button>
            <p>Visit Count:{visit_count}</p>
        </main>
    );
}