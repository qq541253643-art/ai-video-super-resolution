const state = {
  selected: new Map(),
  jobs: [],
  environment: null,
  lastOutput: null,
};

const el = Object.fromEntries([
  "version", "deviceState", "deviceLabel", "queueCount", "queueList", "clearButton",
  "pickButton", "startButton", "faceToggle", "tileSelect", "batchEta", "introPanel",
  "activeRun", "activeName", "activePercent", "activeStage", "activeFps", "activeEta",
  "progressBar", "progressTrack", "completedSummary", "completedText", "gpuName", "realesrganState",
  "codeformerState", "footerStatus", "openFolderButton", "toastRegion",
  "modelChip", "modelChipText", "resourceMode", "pauseButton", "cancelButton",
  "cancelAllButton", "addVideosButton", "completedTitle", "runStateLabel",
].map(id => [id, document.getElementById(id)]));

const api = async (url, options = {}) => {
  const response = await fetch(url, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || `请求失败（${response.status}）`);
  return payload;
};

const toast = (message, type = "info") => {
  const node = document.createElement("div");
  node.className = `toast ${type}`;
  node.textContent = message;
  el.toastRegion.append(node);
  setTimeout(() => node.remove(), 4500);
};

const formatDuration = seconds => {
  if (!Number.isFinite(seconds)) return "—";
  const rounded = Math.max(0, Math.round(seconds));
  const h = Math.floor(rounded / 3600);
  const m = Math.floor((rounded % 3600) / 60);
  const s = rounded % 60;
  return h ? `${h}时 ${String(m).padStart(2, "0")}分` : `${m}分 ${String(s).padStart(2, "0")}秒`;
};

const formatClock = seconds => {
  if (!Number.isFinite(seconds)) return "计算中";
  const date = new Date(Date.now() + seconds * 1000);
  return `${date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })}（${formatDuration(seconds)}）`;
};

const stateLabel = status => ({ queued: "等待中", running: "处理中", completed: "已完成", failed: "失败",
  pausing: "正在暂停", paused: "已暂停", waiting: "等待资源", cancelling: "正在终止", cancelled: "已取消" }[status] || "待开始");
const activeStatuses = new Set(["running", "pausing", "paused", "waiting", "cancelling"]);

const estimateSeconds = item => {
  const meta = item.metadata || {};
  const megapixels = (Number(meta.width) * Number(meta.height)) / 1e6;
  const frames = Number(meta.duration) * Number(meta.fps);
  if (!Number.isFinite(megapixels) || !Number.isFinite(frames)) return 0;
  const faceSecondsPerFrame = el.faceToggle.checked ? 1.1 : 0;
  const yieldFactor = el.resourceMode.value === "smooth" ? 2.5 : 1;
  return Math.max(30, frames * (megapixels * 8.0 + faceSecondsPerFrame) * yieldFactor);
};

function renderSelected() {
  const items = [...state.selected.values()];
  if (!items.length && !state.jobs.length) {
    el.queueList.innerHTML = `<div class="empty-queue">
      <svg viewBox="0 0 48 48" aria-hidden="true"><path d="M8 12h13l4 5h15v22H8zM16 28h16M24 22v12"/></svg>
      <strong>队列还是空的</strong><span>一次可选择多个视频</span></div>`;
    el.queueCount.textContent = "尚未导入视频";
    el.startButton.disabled = true;
    el.batchEta.textContent = "等待导入";
    return;
  }
  const pending = items.map(item => ({ ...item, status: "selected", progress: 0 }));
  renderQueue([...state.jobs, ...pending]);
  el.startButton.disabled = !items.length || !state.environment?.ready;
  const seconds = items.reduce((sum, item) => sum + estimateSeconds(item), 0);
  el.batchEta.textContent = formatClock(seconds);
}

function renderQueue(jobs) {
  el.queueCount.textContent = `${jobs.length} 个视频`;
  el.queueList.innerHTML = jobs.map(job => {
    const meta = job.metadata || {};
    const percent = Math.round((job.progress || 0) * 100);
    const stateClass = job.status === "selected" ? "" : job.status;
    return `<article class="queue-item">
      <div class="queue-item-head">
        <span class="file-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M5 3h10l4 4v14H5zM14 3v5h5M9 12l6 3-6 3z"/></svg></span>
        <div class="file-copy"><strong title="${escapeHtml(job.path)}">${escapeHtml(job.name || job.path.split(/[\\/]/).pop())}</strong>
          <span>${meta.width || "—"}×${meta.height || "—"} · ${meta.fps ? Number(meta.fps).toFixed(2) : "—"} fps · ${formatDuration(meta.duration)}</span></div>
        <span class="job-state ${stateClass}">${job.status === "selected" ? "待提交" : stateLabel(job.status)}</span>
      </div>
      ${job.status === "running" ? `<div class="mini-progress"><span style="width:${percent}%"></span></div>` : ""}
      ${job.error ? `<p class="job-error">${escapeHtml(job.error)}</p>` : ""}
    </article>`;
  }).join("");
}

const escapeHtml = value => String(value).replace(/[&<>'"]/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[char]));

async function loadEnvironment() {
  try {
    const env = await api("/api/status");
    state.environment = env;
    el.version.textContent = `v${env.version}`;
    el.gpuName.textContent = env.gpu.total_mb ? `${env.gpu.name} · ${Math.round(env.gpu.total_mb / 1024)}GB` : "未检测到";
    const backend = env.realesrgan_backend === "cuda" ? "CUDA" : "Vulkan";
    el.realesrganState.textContent = env.realesrgan ? `已安装 · ${backend}` : "未安装";
    el.codeformerState.textContent = env.codeformer ? "已安装" : "未安装";
    el.faceToggle.disabled = !env.codeformer;
    el.modelChipText.textContent = env.realesrgan ? `Real-ESRGAN · ${backend}` : "Real-ESRGAN 未就绪";
    el.deviceState.className = `device-state ${env.ready ? "ready" : "error"}`;
    el.deviceLabel.textContent = env.ready ? `${env.gpu.name} · 本机推理` : "环境未就绪，请重新安装";
    el.footerStatus.textContent = env.ready ? "模型与 FFmpeg 已就绪" : "环境检查未通过";
    renderSelected();
  } catch (error) {
    el.deviceState.className = "device-state error";
    el.deviceLabel.textContent = "无法连接本机服务";
    toast(error.message, "error");
  }
}

async function pickFiles() {
  el.pickButton.disabled = true;
  el.addVideosButton.disabled = true;
  el.footerStatus.textContent = "正在打开文件选择器…";
  try {
    const payload = await api("/api/pick", { method: "POST", body: "{}" });
    payload.files.forEach(file => state.selected.set(file.path, { path: file.path, name: file.path.split(/[\\/]/).pop(), metadata: file.metadata }));
    if (payload.files.length) toast(`已加入 ${payload.files.length} 个视频`);
    renderSelected();
  } catch (error) {
    toast(error.message, "error");
  } finally {
    el.pickButton.disabled = false;
    el.addVideosButton.disabled = false;
    el.footerStatus.textContent = "准备就绪";
  }
}

async function startJobs() {
  const paths = [...state.selected.keys()];
  if (!paths.length) return;
  el.startButton.disabled = true;
  try {
    const payload = await api("/api/jobs", {
      method: "POST",
      body: JSON.stringify({ paths, tile: Number(el.tileSelect.value), face_enhance: el.faceToggle.checked,
        resource_mode: el.resourceMode.value }),
    });
    state.jobs.push(...payload.jobs);
    state.selected.clear();
    toast(`${payload.jobs.length} 个视频已开始排队`);
    await pollJobs();
  } catch (error) {
    toast(error.message, "error");
    renderSelected();
  }
}

async function pollJobs() {
  try {
    const payload = await api("/api/jobs");
    state.jobs = payload.jobs;
    if (!state.jobs.length && !state.selected.size) renderSelected();
    else renderQueue([...state.jobs, ...[...state.selected.values()].map(item => ({ ...item, status: "selected" }))]);
    const active = state.jobs.find(job => activeStatuses.has(job.status));
    const completed = state.jobs.filter(job => job.status === "completed");
    const queued = state.jobs.filter(job => job.status === "queued");
    const failed = state.jobs.filter(job => job.status === "failed");
    const cancelled = state.jobs.filter(job => job.status === "cancelled");
    el.cancelAllButton.hidden = !active && !queued.length;
    if (active) {
      el.runStateLabel.textContent = stateLabel(active.status);
      el.pauseButton.textContent = ["paused", "pausing"].includes(active.status) ? "继续" : "暂停";
      el.pauseButton.disabled = active.status === "cancelling";
      el.cancelButton.disabled = active.status === "cancelling";
      el.introPanel.hidden = true;
      el.completedSummary.hidden = true;
      el.activeRun.hidden = false;
      const percent = Math.round(active.progress * 100);
      el.activeName.textContent = active.name;
      el.activePercent.textContent = `${percent}%`;
      el.progressBar.style.width = `${percent}%`;
      el.progressTrack.setAttribute("aria-valuenow", String(percent));
      el.activeStage.textContent = active.stage;
      el.activeFps.textContent = active.stage_fps ? `${Number(active.stage_fps).toFixed(2)} 帧/秒` : "计算中";
      const stageRemaining = active.remaining_seconds === null ? NaN : Number(active.remaining_seconds);
      const activeRemaining = Number.isFinite(stageRemaining) && stageRemaining > 0
        ? stageRemaining
        : estimateSeconds(active) * Math.max(0, 1 - active.progress);
      el.activeEta.textContent = formatClock(activeRemaining);
      const pendingSeconds = queued.reduce((sum, job) => sum + estimateSeconds(job), 0)
        + [...state.selected.values()].reduce((sum, item) => sum + estimateSeconds(item), 0);
      el.batchEta.textContent = formatClock(activeRemaining + pendingSeconds);
      if (["paused", "pausing", "waiting", "cancelling"].includes(active.status)) {
        el.activeEta.textContent = stateLabel(active.status);
        el.batchEta.textContent = "恢复处理后重新估算";
        el.activeFps.textContent = "—";
      }
      el.footerStatus.textContent = `${active.stage} · ${percent}%`;
    } else if (state.jobs.length && !queued.length) {
      el.activeRun.hidden = true;
      el.introPanel.hidden = true;
      el.completedSummary.hidden = false;
      el.completedSummary.classList.toggle("has-errors", !!failed.length);
      el.completedSummary.classList.toggle("was-cancelled", !!cancelled.length && !failed.length);
      el.completedTitle.textContent = failed.length ? "批次已结束，有任务失败" : cancelled.length ? "批次已结束，有任务取消" : "本批次已完成";
      el.completedSummary.querySelector("svg").toggleAttribute("hidden", !!failed.length || !!cancelled.length);
      el.completedText.textContent = `${completed.length} 个完成，${failed.length} 个失败，${cancelled.length} 个取消`;
      el.batchEta.textContent = failed.length ? "有失败项目" : cancelled.length ? "已结束" : "全部完成";
      el.footerStatus.textContent = failed.length ? "请查看左侧失败原因；修复后可重新添加视频" : cancelled.length ? "已完成的输出保留，源视频未修改" : "批次处理完成";
      if (completed.length) {
        state.lastOutput = completed.at(-1).outputs.hd;
        el.openFolderButton.hidden = false;
      }
    }
    el.startButton.disabled = !state.selected.size || !state.environment?.ready;
  } catch (error) {
    el.footerStatus.textContent = "状态刷新失败";
  }
}

el.pickButton.addEventListener("click", pickFiles);
el.addVideosButton.addEventListener("click", pickFiles);
async function controlJob(action, all = false) {
  const active = state.jobs.find(job => activeStatuses.has(job.status));
  if (!all && !active) return;
  if (action === "cancel" && !window.confirm(all ? "终止当前视频并取消全部排队？已完成输出保留，源视频不变。" : "终止当前视频？已完成输出保留，源视频不变；其他排队视频仍会继续。")) return;
  try {
    await api("/api/job-action", { method: "POST", body: JSON.stringify({ id: all ? "all" : active.id, action }) });
    await pollJobs();
  } catch (error) { toast(error.message, "error"); }
}
el.pauseButton.addEventListener("click", () => {
  const active = state.jobs.find(job => activeStatuses.has(job.status));
  controlJob(active && ["paused", "pausing"].includes(active.status) ? "resume" : "pause");
});
el.cancelButton.addEventListener("click", () => controlJob("cancel"));
el.cancelAllButton.addEventListener("click", () => controlJob("cancel", true));
el.startButton.addEventListener("click", startJobs);
el.clearButton.addEventListener("click", () => { state.selected.clear(); renderSelected(); });
el.faceToggle.addEventListener("change", renderSelected);
el.tileSelect.addEventListener("change", renderSelected);
el.resourceMode.addEventListener("change", renderSelected);
el.openFolderButton.addEventListener("click", async () => {
  if (!state.lastOutput) return;
  try { await api("/api/open-folder", { method: "POST", body: JSON.stringify({ path: state.lastOutput }) }); }
  catch (error) { toast(error.message, "error"); }
});

loadEnvironment();
pollJobs();
setInterval(pollJobs, 1000);
