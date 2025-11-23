(async function main() {
  setupHotReload();
})();

function setupHotReload() {
  const eventSource = new EventSource("/_zx/devsocket");
  let hasEverConnected = false,
    isReconnecting = false;

  eventSource.onopen = () => {
    if (isReconnecting && hasEverConnected) {
      eventSource.close();
      location.reload();
      
    } else {
      hasEverConnected = true;
      isReconnecting = false;
    }
  };

  eventSource.onerror = () => (isReconnecting = hasEverConnected);
}
