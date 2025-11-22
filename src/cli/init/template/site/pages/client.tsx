import { useState } from "react";

export default function Page(props: { counter: number }) {
    const [count, setCount] = useState(props.counter);

    return (
        <div>
            <button onClick={updateCount(0)}>Reset</button>
            <h5>{count}</h5>
            <button onClick={updateCount(-1)}>Decrement</button>
            <button onClick={updateCount(1)}>Increment</button>
        </div>
    );

    function updateCount(n: number) {
        return () => {
            setCount(c => n === 0 ? 0 : c + n);
            if (n === 0) fetch(`?reset=true`);
            if (n > 0) fetch(`?increment=true`);
            if (n < 0) fetch(`?decrement=true`);
        }
    };
}