// Two more gauges in the top row, next to CPU, memory and disk: the hard drives' free space, and the UPS battery.
// Homepage's top-row widgets can't read other sources, so the values come from hidden tiles in services.yaml
// (Drives and Battery, through Homepage's own proxy, which reaches scripts/pool-status.py and
// modules/ups/ups-status.py on the server). A gauge is left out while its source has nothing to show.
(() => {
  const svg = (shapes) =>
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
    `stroke-linejoin="round" class="w-5 h-5 resource-icon">${shapes}</svg>`;

  // "17.6 TB": decimal units, like the sizes printed on the drives.
  const size = (bytes) => {
    const units = ["B", "KB", "MB", "GB", "TB", "PB"];
    let i = 0;
    while (bytes >= 1000 && i < units.length - 1) (bytes /= 1000), i++;
    return `${bytes.toFixed(bytes < 100 && i > 0 ? 1 : 0)} ${units[i]}`;
  };

  // "On battery 25m": time left matters only when the battery is in use.
  const power = (u) => {
    if (!u.power.startsWith("On battery") && !u.power.startsWith("Battery low")) return u.power;
    const min = Math.round((u.runtime ?? 0) / 60);
    return `${u.power} ${min >= 60 ? `${Math.floor(min / 60)}h${String(min % 60).padStart(2, "0")}` : `${min}m`}`;
  };

  // view(data) gives what the gauge shows, or null to leave it out.
  const GAUGES = [
    {
      name: "drives",
      source: "/api/services/proxy?group=Server&service=Drives&index=0",
      every: 60000,
      icon: svg('<line x1="22" y1="12" x2="2" y2="12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><line x1="6" y1="16" x2="6.01" y2="16"/><line x1="10" y1="16" x2="10.01" y2="16"/>'),
      view: (p) =>
        p?.free == null
          ? null
          : {
              value: size(p.free),
              label: p.health === "ONLINE" ? "Drives free" : p.health,
              fill: (100 * p.used) / (p.used + p.free),
              title: `Hard drives: ${size(p.free)} free of ${size(p.used + p.free)}, ${p.health === "ONLINE" ? "healthy" : p.health}`,
            },
    },
    {
      name: "ups",
      source: "/api/services/proxy?group=Server&service=Battery&index=0",
      every: 30000,
      icon: svg('<rect x="2" y="7" width="16" height="10" rx="2"/><line x1="22" y1="11" x2="22" y2="13"/>'),
      view: (u) =>
        u?.charge == null
          ? null
          : { value: `${u.charge}%`, label: power(u), fill: u.charge, title: `UPS: ${u.power}, ${u.charge}% charged` },
    },
  ];

  const render = () => {
    const row = document.querySelector("#information-widgets .information-widget-resource")?.parentElement;
    if (!row) return;
    for (const g of GAUGES) {
      let item = row.querySelector(`.information-widget-${g.name}`);
      const v = g.view(g.data);
      if (!v) {
        item?.remove();
        continue;
      }
      if (!item) {
        item = document.createElement("div");
        item.className = `flex-none flex flex-row items-center mr-3 py-1.5 information-widget-resource information-widget-${g.name}`;
        item.innerHTML =
          g.icon +
          '<div class="flex flex-col ml-3 text-left min-w-[85px]"><div class="text-xs flex flex-row justify-between gap-2">' +
          '<div class="pl-0.5 resource-value"></div><div class="pr-1 gauge-label"></div></div>' +
          '<div class="mt-0.5 w-full rounded-full h-1 resource-usage"><div class="h-1 rounded-full"></div></div></div>';
      }
      row.appendChild(item); // (re)appending keeps the gauges in GAUGES order, after Homepage's own
      item.title = v.title;
      item.querySelector(".resource-value").textContent = v.value;
      item.querySelector(".gauge-label").textContent = v.label;
      item.querySelector(".resource-usage > div").style.width = `${Math.min(100, Math.max(0, v.fill))}%`;
    }
  };

  for (const g of GAUGES) {
    const refresh = async () => {
      try {
        const res = await fetch(g.source);
        g.data = res.ok ? await res.json() : null;
      } catch {
        g.data = null;
      }
      render();
    };
    refresh();
    setInterval(refresh, g.every);
  }
  // The page redraws its widgets now and then; put the gauges back if they went missing.
  setInterval(render, 2000);
})();
