import "vite/modulepreload-polyfill";
import "./styles.css";

const status = document.querySelector<HTMLElement>("[data-asset-status]");

if (status !== null) {
  status.dataset.state = "ready";
  status.textContent = "Asset bundle loaded.";
}

document.documentElement.dataset.assetPipeline = "ready";
