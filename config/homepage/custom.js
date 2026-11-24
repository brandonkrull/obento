// The UPS battery as one more gauge in the top row, next to CPU, memory and disk.
// Homepage's top-row widgets can't read other sources, so the values come from the hidden Battery tile in
// services.yaml (through Homepage's own proxy, which reaches scripts/ups-status.py on the server).
(() => {
  const SOURCE = "/api/services/proxy?group=Server&service=Battery&index=0";
  const ICON =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
    'stroke-linejoin="round" class="w-5 h-5 resource-icon"><rect x="2" y="7" width="16" height="10" rx="2"/>' +
    '<line x1="22" y1="11" x2="22" y2="13"/></svg>';
  let ups = null;

  // "On battery 25m": time left matters only when the battery is in use.
  const label = (u) => {
    if (!u.power.startsWith("On battery") && !u.power.startsWith("Battery low")) return u.power;
    const min = Math.round((u.runtime ?? 0) / 60);
    return `${u.power} ${min >= 60 ? `${Math.floor(min / 60)}h${String(min % 60).padStart(2, "0")}` : `${min}m`}`;
  };

  const render = () => {
    const row = document.querySelector("#information-widgets .information-widget-resource")?.parentElement;
    if (!row) return;
    let item = row.querySelector(".information-widget-ups");
    if (ups?.charge == null) {
      item?.remove();
      return;
    }
    if (!item) {
      item = document.createElement("div");
      item.className = "flex-none flex flex-row items-center mr-3 py-1.5 information-widget-resource information-widget-ups";
      item.innerHTML =
        ICON +
        '<div class="flex flex-col ml-3 text-left min-w-[85px]"><div class="text-xs flex flex-row justify-between gap-2">' +
        '<div class="pl-0.5 resource-value"></div><div class="pr-1 ups-label"></div></div>' +
        '<div class="mt-0.5 w-full rounded-full h-1 resource-usage"><div class="h-1 rounded-full"></div></div></div>';
      row.appendChild(item);
    }
    item.title = `UPS: ${ups.power}, ${ups.charge}% charged`;
    item.querySelector(".resource-value").textContent = `${ups.charge}%`;
    item.querySelector(".ups-label").textContent = label(ups);
    item.querySelector(".resource-usage > div").style.width = `${Math.min(100, Math.max(0, ups.charge))}%`;
  };

  const refresh = async () => {
    try {
      const res = await fetch(SOURCE);
      ups = res.ok ? await res.json() : null;
    } catch {
      ups = null;
    }
    render();
  };

  refresh();
  setInterval(refresh, 30000);
  // The page redraws its widgets now and then; put the gauge back if it went missing.
  setInterval(render, 2000);
})();
