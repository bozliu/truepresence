const elements = {
  apiBase: document.querySelector("#apiBase"),
  connectButton: document.querySelector("#connectButton"),
  refreshButton: document.querySelector("#refreshButton"),
  fullResetButton: document.querySelector("#fullResetButton"),
  clearEventsButton: document.querySelector("#clearEventsButton"),
  resetLog: document.querySelector("#resetLog"),
  sessionPersonID: document.querySelector("#sessionPersonID"),
  latitude: document.querySelector("#latitude"),
  longitude: document.querySelector("#longitude"),
  accuracyM: document.querySelector("#accuracyM"),
  classLabel: document.querySelector("#classLabel"),
  sessionStartButton: document.querySelector("#sessionStartButton"),
  liveSessionCard: document.querySelector("#liveSessionCard"),
  generateQRButton: document.querySelector("#generateQRButton"),
  bindingQRCard: document.querySelector("#bindingQRCard"),
  transportStatus: document.querySelector("#transportStatus"),
  streamStatus: document.querySelector("#streamStatus"),
  stats: document.querySelector("#stats"),
  heroCopy: document.querySelector("#heroCopy"),
  cameraPreview: document.querySelector("#cameraPreview"),
  captureCanvas: document.querySelector("#captureCanvas"),
  cameraStatus: document.querySelector("#cameraStatus"),
  cameraHint: document.querySelector("#cameraHint"),
  startCameraButton: document.querySelector("#startCameraButton"),
  stopCameraButton: document.querySelector("#stopCameraButton"),
  enrollButton: document.querySelector("#enrollButton"),
  uploadInput: document.querySelector("#uploadInput"),
  uploadEnrollButton: document.querySelector("#uploadEnrollButton"),
  enrollmentCard: document.querySelector("#enrollmentCard"),
  shotGuideCard: document.querySelector("#shotGuideCard"),
  iphoneStatus: document.querySelector("#iphoneStatus"),
  runtimeCard: document.querySelector("#runtimeCard"),
  events: document.querySelector("#events"),
  tenantsList: document.querySelector("#tenantsList"),
  peopleList: document.querySelector("#peopleList"),
  templatesList: document.querySelector("#templatesList"),
  capturesList: document.querySelector("#capturesList"),
  newPersonName: document.querySelector("#newPersonName"),
  addPersonButton: document.querySelector("#addPersonButton"),
};

const guidedShotRoles = [
  { role: "front", label: "Front face", hint: "Look straight into the Mac camera." },
  { role: "slight_left", label: "Slight left turn", hint: "Rotate your face a little to the left." },
  { role: "slight_right", label: "Slight right turn", hint: "Rotate your face a little to the right." },
];

let mediaStream = null;
let eventSource = null;
let currentSnapshot = null;
let currentTenants = [];
let selectedUploadDataURL = null;
let enrollmentSequenceID = null;
let nextShotIndex = 1;
let preferredSessionPersonID = null;
let latestBindingQR = null;
let qrCodeModulePromise = null;

function apiBaseURL() {
  return elements.apiBase.value.trim().replace(/\/$/, "");
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function prettyTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

function pill(label, kind = "") {
  return `<span class="pill ${kind}">${escapeHTML(label)}</span>`;
}

function shotRoleFor(index) {
  return guidedShotRoles[Math.max(0, Math.min(index - 1, guidedShotRoles.length - 1))];
}

function activeLivePersonID() {
  return currentSnapshot?.live_person?.id ?? null;
}

function selectedStudentID() {
  return elements.sessionPersonID.value || preferredSessionPersonID || activeLivePersonID();
}

function demoPeople(snapshot = currentSnapshot) {
  return (snapshot?.people_summary ?? []).filter((person) => person.person_kind === "demo");
}

function setLog(message) {
  elements.resetLog.textContent =
    typeof message === "string" ? message : JSON.stringify(message, null, 2);
}

function showEnrollmentError(message) {
  const safeMessage = escapeHTML(message || "Enrollment failed.");
  elements.enrollmentCard.innerHTML = `
    <strong>Capture did not complete.</strong>
    <span>${safeMessage}</span>
  `;
  elements.cameraHint.textContent = safeMessage;
  setLog(message);
}

function scrollToPanel(id) {
  document.querySelector(`#${id}`)?.scrollIntoView({ behavior: "smooth", block: "start" });
}

async function fetchJSON(path, options = {}) {
  const response = await fetch(`${apiBaseURL()}${path}`, {
    headers: {
      "Content-Type": "application/json",
    },
    ...options,
  });
  if (!response.ok) {
    let detail;
    try {
      detail = await response.text();
    } catch {
      detail = `HTTP ${response.status}`;
    }
    throw new Error(detail || `HTTP ${response.status}`);
  }
  return response.json();
}

async function refreshTenants() {
  currentTenants = await fetchJSON("/v1/tenants");
}

async function refreshSnapshot() {
  const snapshot = await fetchJSON("/v1/demo/control/snapshot?tenant_id=truepresence-demo");
  currentSnapshot = snapshot;
  renderSnapshot(snapshot);
  elements.transportStatus.textContent = "Connected to local backend";
}

function startStream() {
  if (eventSource) {
    eventSource.close();
  }
  eventSource = new EventSource(`${apiBaseURL()}/v1/demo/control/stream?tenant_id=truepresence-demo`);
  elements.streamStatus.textContent = "connecting";
  eventSource.addEventListener("snapshot", (event) => {
    currentSnapshot = JSON.parse(event.data);
    renderSnapshot(currentSnapshot);
    elements.streamStatus.textContent = "live";
  });
  eventSource.onerror = () => {
    elements.streamStatus.textContent = "reconnecting";
  };
}

async function connectConsole() {
  await Promise.all([refreshTenants(), refreshSnapshot()]);
  startStream();
}

function renderStats(snapshot) {
  const stats = [
    ["Tenants", currentTenants.length, "tenantsPanel"],
    ["Students", snapshot.people_summary.length, "peoplePanel"],
    ["Templates", snapshot.template_summary.length, "templatesPanel"],
    ["Captures", snapshot.capture_summary.length, "capturesPanel"],
    ["Events", snapshot.recent_events.length, "eventsPanel"],
  ];
  elements.stats.innerHTML = stats
    .map(
      ([label, value, panelID]) => `
        <button class="stat stat-button" type="button" data-panel="${panelID}">
          <p class="eyebrow">${escapeHTML(label)}</p>
          <strong>${value}</strong>
        </button>
      `
    )
    .join("");
  elements.stats.querySelectorAll(".stat-button").forEach((button) => {
    button.addEventListener("click", () => scrollToPanel(button.dataset.panel));
  });
}

function renderHero(snapshot) {
  if (snapshot.live_session?.last_mac_enrollment_at) {
    elements.heroCopy.textContent =
      "Enrollment is ready. Generate the student QR, let the iPhone bind once, then run TrueDepth liveness and classroom check-in against the same backend.";
    return;
  }
  if (snapshot.active_class_session) {
    elements.heroCopy.textContent =
      "The class session is live. Capture the three guided enrollment shots or upload one fallback photo, then bind the iPhone student by QR.";
    return;
  }
  elements.heroCopy.textContent =
    "Start with a full reset, add a student, create the active class session, enroll from this Mac, generate the binding QR, then let the iPhone verify against the same backend in realtime.";
}

function renderTenants() {
  if (!currentTenants.length) {
    elements.tenantsList.innerHTML = `
      <div class="summary-card">
        <strong>No tenants loaded.</strong>
        <span>Connect the console to the local backend first.</span>
      </div>
    `;
    return;
  }
  elements.tenantsList.innerHTML = currentTenants
    .map(
      (tenant) => `
        <div class="row-card">
          <div>
            <strong>${escapeHTML(tenant.name)}</strong>
            <div class="row-meta">${escapeHTML(tenant.id)} · ${escapeHTML(tenant.timezone)}</div>
          </div>
        </div>
      `
    )
    .join("");
}

function renderLiveSession(snapshot) {
  const demos = demoPeople(snapshot);
  const selectedPersonID =
    preferredSessionPersonID
    ?? snapshot.live_person?.id
    ?? demos[0]?.id
    ?? "";
  elements.sessionPersonID.innerHTML = demos.length
    ? demos
        .map(
          (person) => `
            <option value="${escapeHTML(person.id)}" ${person.id === selectedPersonID ? "selected" : ""}>
              ${escapeHTML(person.display_name)}${person.active_live_session ? " · active" : ""}
            </option>
          `
        )
        .join("")
    : `<option value="">No students yet</option>`;
  elements.sessionPersonID.disabled = demos.length === 0;
  elements.sessionStartButton.disabled = demos.length === 0;

  const session = snapshot.live_session;
  const activeClass = snapshot.active_class_session;
  if (!session || !snapshot.live_person || !snapshot.live_site || !activeClass) {
    elements.liveSessionCard.innerHTML = `
      <strong>No active class session yet.</strong>
      <span>Add a student first, then create the class session for the classroom location here.</span>
    `;
    return;
  }
  elements.latitude.value = Number(snapshot.live_site.latitude).toFixed(6);
  elements.longitude.value = Number(snapshot.live_site.longitude).toFixed(6);
  elements.accuracyM.value = Math.max(Math.round(snapshot.live_site.radius_m / 3), 12);
  elements.liveSessionCard.innerHTML = `
    <strong>${escapeHTML(activeClass.class_label)}</strong>
    <span>${escapeHTML(snapshot.live_person.display_name)} · ${escapeHTML(snapshot.live_site.label)} · radius ${Math.round(snapshot.live_site.radius_m)}m</span>
    <span>${session.last_mac_enrollment_at ? `Last enrollment ${prettyTime(session.last_mac_enrollment_at)}` : "Waiting for Mac enrollment"}</span>
  `;
}

function renderEnrollmentStage(snapshot) {
  const hasActiveSession = Boolean(snapshot.live_person && snapshot.live_site);
  elements.enrollButton.disabled = hasActiveSession === false;
  elements.uploadEnrollButton.disabled = hasActiveSession === false;
  elements.uploadInput.disabled = hasActiveSession === false;
  elements.enrollButton.textContent = hasActiveSession
    ? `Capture ${shotRoleFor(nextShotIndex).label}`
    : "Start class above to enable capture";
  elements.uploadEnrollButton.textContent = hasActiveSession
    ? "Upload & Enroll Fallback"
    : "Start class above to enable upload";

  if (hasActiveSession) {
    elements.cameraHint.textContent = "Frame one face and follow the guided three-shot enrollment.";
    if (!currentSnapshot?.live_session?.last_mac_enrollment_at) {
      elements.enrollmentCard.innerHTML = `
        <strong>No shared enrollment has been captured yet.</strong>
        <span>The active class session is ready. Capture the guided Mac shots or upload one fallback photo next.</span>
      `;
    }
    return;
  }

  elements.enrollmentCard.innerHTML = `
    <strong>Capture is locked until class starts.</strong>
    <span>Go to <em>Active Class Session</em>, pick the student, confirm the classroom coordinates, and click <em>Start Class Here</em>. Then this Mac capture flow unlocks immediately.</span>
  `;
  if (!mediaStream) {
    elements.cameraHint.textContent = "Open the Mac camera after the class session is active, then capture the guided shots.";
  }
}

function renderPeople(snapshot) {
  if (!snapshot.people_summary.length) {
    elements.peopleList.innerHTML = `
      <div class="summary-card">
        <strong>No students available.</strong>
        <span>Add a student here before creating the class session.</span>
      </div>
    `;
    return;
  }
  elements.peopleList.innerHTML = `
    <div class="table">
      ${snapshot.people_summary
        .map((person) => {
          const badges = [
            pill(person.person_kind === "demo" ? "Teacher Added" : "Built-in", person.person_kind === "demo" ? "warn" : ""),
            pill(`${person.template_count} template${person.template_count === 1 ? "" : "s"}`),
            pill(`${person.capture_count} capture${person.capture_count === 1 ? "" : "s"}`),
            person.active_live_session ? pill("Selected for class", "good") : "",
          ].join("");
          return `
            <div class="table-row">
              <div>
                <strong>${escapeHTML(person.display_name)}</strong>
                <div class="row-meta">${escapeHTML(person.employee_code)} · ${escapeHTML(person.id)}</div>
                <div class="pill-row">${badges}</div>
              </div>
              <div class="row-actions">
                <button type="button" class="ghost generate-person-qr" data-person-id="${escapeHTML(person.id)}">QR</button>
                ${person.deletable
                  ? `<button type="button" class="ghost delete-person" data-person-id="${escapeHTML(person.id)}">Delete</button>`
                  : `<span class="row-meta">Read only</span>`}
              </div>
            </div>
          `;
        })
        .join("")}
    </div>
  `;
  elements.peopleList.querySelectorAll(".generate-person-qr").forEach((button) => {
    button.addEventListener("click", () => generateBindingQR(button.dataset.personId));
  });
  elements.peopleList.querySelectorAll(".delete-person").forEach((button) => {
    button.addEventListener("click", () => deletePerson(button.dataset.personId));
  });
}

function renderTemplates(snapshot) {
  if (!snapshot.template_summary.length) {
    elements.templatesList.innerHTML = `
      <div class="summary-card">
        <strong>No shared templates yet.</strong>
        <span>Mac enrollment will create the shared protected template set here.</span>
      </div>
    `;
    return;
  }
  elements.templatesList.innerHTML = `
    <div class="table">
      ${snapshot.template_summary
        .map(
          (template) => `
            <div class="table-row">
              <div>
                <strong>${escapeHTML(template.person_display_name ?? template.person_id)}</strong>
                <div class="row-meta">${escapeHTML(template.id)} · ${escapeHTML(template.source)}</div>
              </div>
              <div class="row-meta">${prettyTime(template.created_at)}</div>
            </div>
          `
        )
        .join("")}
    </div>
  `;
}

function renderCaptures(snapshot) {
  if (!snapshot.capture_summary.length) {
    elements.capturesList.innerHTML = `
      <div class="summary-card">
        <strong>No capture images saved yet.</strong>
        <span>Mac enrollment and iPhone verification previews will appear here and in Finder under data/runtime/captures.</span>
      </div>
    `;
    return;
  }
  elements.capturesList.innerHTML = snapshot.capture_summary
    .map((capture) => {
      const imageURL = `${apiBaseURL()}/v1/demo/control/captures/${capture.id}/image`;
      return `
        <article class="capture-card">
          <img src="${imageURL}" alt="${escapeHTML(capture.person_display_name ?? capture.person_id ?? "capture")}" />
          <div class="capture-copy">
            <strong>${escapeHTML(capture.person_display_name ?? capture.person_id ?? "Unknown person")}</strong>
            <div class="pill-row">
              ${pill(capture.source)}
              ${pill(capture.stage, capture.stage === "verification" ? "good" : "")}
              ${capture.shot_role ? pill(capture.shot_role) : ""}
            </div>
            <div class="row-meta">${prettyTime(capture.created_at)}</div>
            <div class="row-meta">${escapeHTML(capture.file_path)}</div>
            <div class="row-meta">
              quality ${Number(capture.quality_score ?? 0).toFixed(2)} · detect ${Number(capture.detection_score ?? 0).toFixed(2)}
              ${capture.match_score != null ? ` · match ${Number(capture.match_score).toFixed(2)}` : ""}
              ${capture.liveness_score != null ? ` · liveness ${Number(capture.liveness_score).toFixed(2)}` : ""}
            </div>
          </div>
        </article>
      `;
    })
    .join("");
}

function renderRuntime(snapshot) {
  elements.runtimeCard.innerHTML = `
    <div class="kv"><span>Wi-Fi IPv4</span><strong>${escapeHTML(snapshot.wifi_ipv4 ?? "Unavailable")}</strong></div>
    <div class="kv"><span>Canonical LAN URL</span><strong>${escapeHTML(snapshot.canonical_lan_url ?? "Unavailable")}</strong></div>
    <div class="kv"><span>Bind host</span><strong>${escapeHTML(snapshot.backend_bind_host ?? "unknown")}</strong></div>
    <div class="kv"><span>LAN ready</span><strong>${snapshot.lan_ready ? "true" : "false"}</strong></div>
    <div class="kv"><span>Method profile</span><strong>${escapeHTML(snapshot.method_stack.profile_id)}</strong></div>
    <div class="kv"><span>Capture profile</span><strong>${escapeHTML(snapshot.capture_profile.label)}</strong></div>
    <div class="kv"><span>Face runtime</span><strong>${escapeHTML(snapshot.face_demo_runtime.label)}</strong></div>
    <div class="kv"><span>Runtime status</span><strong>${escapeHTML(snapshot.face_demo_runtime.status)}</strong></div>
    <div class="kv"><span>Network hint</span><strong>${escapeHTML(snapshot.network_hint ?? "Keep the iPhone and Mac on the same Wi-Fi.")}</strong></div>
  `;
}

async function renderBindingQRCode(payload) {
  if (!payload) {
    elements.bindingQRCard.innerHTML = `
      <strong>No QR generated yet.</strong>
      <span>Generate a QR code for the selected student after the class session is ready.</span>
    `;
    return;
  }

  try {
    qrCodeModulePromise ||= import("https://esm.sh/qrcode@1.5.4");
    const module = await qrCodeModulePromise;
    const dataURL = await module.default.toDataURL(payload.qr_payload, {
      margin: 1,
      width: 240,
      color: {
        dark: "#101010",
        light: "#ffffff",
      },
    });
    elements.bindingQRCard.innerHTML = `
      <strong>${escapeHTML(payload.person.display_name)}</strong>
      <span>Expires ${prettyTime(payload.expires_at)}</span>
      <img class="qr-image" src="${dataURL}" alt="Binding QR for ${escapeHTML(payload.person.display_name)}" />
      <code>${escapeHTML(payload.token)}</code>
    `;
  } catch (error) {
    elements.bindingQRCard.innerHTML = `
      <strong>${escapeHTML(payload.person.display_name)}</strong>
      <span>QR generation failed in the browser. The short-lived token is still ready.</span>
      <code>${escapeHTML(payload.qr_payload)}</code>
    `;
    setLog(error.message);
  }

  elements.bindingQRCard.classList.remove("flash-focus");
  void elements.bindingQRCard.offsetWidth;
  elements.bindingQRCard.classList.add("flash-focus");
  elements.bindingQRCard.scrollIntoView({ behavior: "smooth", block: "center" });
}

function renderIPhoneStatus(snapshot) {
  const session = snapshot.live_session;
  if (!session?.phone_last_seen_at) {
    elements.iphoneStatus.innerHTML = `
      <div class="summary-card">
        <strong>Waiting for the iPhone.</strong>
        <span>Open the app on the same LAN, switch to LAN realtime, and refresh bootstrap.</span>
      </div>
    `;
    return;
  }
  elements.iphoneStatus.innerHTML = `
    <div class="kv"><span>Last seen</span><strong>${prettyTime(session.phone_last_seen_at)}</strong></div>
    <div class="kv"><span>Last mobile action</span><strong>${escapeHTML(session.phone_last_status_source ?? "unknown")}</strong></div>
    <div class="kv"><span>App version</span><strong>${escapeHTML(session.phone_last_app_version ?? "unknown")}</strong></div>
    <div class="kv"><span>Latest decision</span><strong>${escapeHTML(snapshot.latest_event?.reason_code ?? "no decision yet")}</strong></div>
  `;
}

function renderEvents(snapshot) {
  if (!snapshot.recent_events.length) {
    elements.events.innerHTML = `
      <div class="summary-card">
        <strong>No attendance decisions yet.</strong>
        <span>Once the iPhone submits the LAN realtime claim, the same result will appear here immediately.</span>
      </div>
    `;
    return;
  }
  elements.events.innerHTML = `
    <div class="feed-list">
      ${snapshot.recent_events
        .map((event) => `
          <article class="feed-item">
            <div class="button-row">
              ${pill(event.accepted ? "Accepted" : "Rejected", event.accepted ? "good" : "bad")}
              ${pill(event.reason_code, event.accepted ? "good" : "bad")}
              ${pill(event.decision_origin)}
            </div>
            <div class="event-shell">
              ${event.capture_id ? `
                <img
                  class="event-thumb"
                  src="${apiBaseURL()}/v1/demo/control/captures/${event.capture_id}/image"
                  alt="${escapeHTML(event.person_display_name ?? event.person_id ?? "capture")}"
                />
              ` : ""}
              <div class="event-copy">
                <strong>${escapeHTML(event.person_display_name ?? event.person_id ?? "Unknown")} → ${escapeHTML(event.matched_person_display_name ?? event.matched_person_id ?? "No match")}</strong>
                <div class="feed-meta">${escapeHTML(event.site_label ?? event.site_id)} · ${prettyTime(event.created_at)}</div>
                <div class="feed-meta">match ${Number(event.match_score).toFixed(2)} · quality ${Number(event.quality_score).toFixed(2)} · liveness ${Number(event.liveness_score).toFixed(2)}</div>
                ${event.capture_file_path ? `<div class="feed-meta">Capture: ${escapeHTML(event.capture_file_path)}</div>` : ""}
              </div>
            </div>
          </article>
        `)
        .join("")}
    </div>
  `;
}

function renderShotGuide() {
  const shot = shotRoleFor(nextShotIndex);
  elements.shotGuideCard.innerHTML = `
    <strong>Guided enrollment shot ${nextShotIndex} of ${guidedShotRoles.length}</strong>
    <span>${escapeHTML(shot.label)} · ${escapeHTML(shot.hint)}</span>
  `;
  if (!elements.enrollButton.disabled) {
    elements.enrollButton.textContent = `Capture ${shot.label}`;
  }
}

function renderSnapshot(snapshot) {
  elements.transportStatus.textContent = snapshot.lan_ready
    ? `LAN ready at ${snapshot.canonical_lan_url ?? "unknown"}`
    : "LAN URL unavailable";
  renderStats(snapshot);
  renderHero(snapshot);
  renderTenants();
  renderLiveSession(snapshot);
  renderEnrollmentStage(snapshot);
  renderPeople(snapshot);
  renderTemplates(snapshot);
  renderCaptures(snapshot);
  renderRuntime(snapshot);
  renderIPhoneStatus(snapshot);
  renderEvents(snapshot);
  renderBindingQRCode(latestBindingQR);
}

async function fullReset() {
  const response = await fetchJSON("/v1/demo/control/reset?tenant_id=truepresence-demo", { method: "POST" });
  setLog(response);
  preferredSessionPersonID = null;
  enrollmentSequenceID = null;
  nextShotIndex = 1;
  renderShotGuide();
  await connectConsole();
}

async function clearEvents() {
  const response = await fetchJSON("/v1/demo/control/events/clear?tenant_id=truepresence-demo", { method: "POST" });
  setLog(response);
  await refreshSnapshot();
}

async function startSession() {
  const personID = elements.sessionPersonID.value;
  if (!personID) {
    setLog("Add or choose a student before starting class.");
    return;
  }
  const payload = {
    tenant_id: "truepresence-demo",
    person_id: personID,
    gps: {
      latitude: Number(elements.latitude.value),
      longitude: Number(elements.longitude.value),
      accuracy_m: Number(elements.accuracyM.value),
      is_mocked: false,
    },
  };
  const response = await fetchJSON("/v1/demo/control/session/start", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  const classResponse = await fetchJSON("/v1/demo/control/class-session/start", {
    method: "POST",
    body: JSON.stringify({
      tenant_id: "truepresence-demo",
      site_id: response.site.id,
      class_label: elements.classLabel.value.trim() || `${response.site.label} Attendance`,
    }),
  });
  preferredSessionPersonID = response.person.id;
  setLog(`Class session created for ${response.person.display_name}. ${classResponse.active_class_session.class_label} is now live.`);
  await refreshSnapshot();
}

async function addPerson() {
  const displayName = elements.newPersonName.value.trim();
  if (!displayName) {
    setLog("Enter a student name first.");
    return;
  }
  const response = await fetchJSON("/v1/demo/control/people", {
    method: "POST",
    body: JSON.stringify({ tenant_id: "truepresence-demo", display_name: displayName }),
  });
  elements.newPersonName.value = "";
  preferredSessionPersonID = response.id;
  setLog(`Added student ${response.display_name}.`);
  await refreshSnapshot();
}

async function deletePerson(personID) {
  const response = await fetchJSON(`/v1/demo/control/people/${personID}?tenant_id=truepresence-demo`, {
    method: "DELETE",
  });
  if (preferredSessionPersonID === personID) {
    preferredSessionPersonID = null;
  }
  setLog(response);
  await refreshSnapshot();
}

async function generateBindingQR(personID = selectedStudentID()) {
  if (!personID) {
    setLog("Choose a student before generating the binding QR.");
    return;
  }
  latestBindingQR = await fetchJSON(`/v1/demo/control/people/${personID}/binding-token?tenant_id=truepresence-demo`, {
    method: "POST",
  });
  await renderBindingQRCode(latestBindingQR);
  setLog(`Binding QR ready for ${latestBindingQR.person.display_name}.`);
}

async function startCamera() {
  if (mediaStream) return;
  mediaStream = await navigator.mediaDevices.getUserMedia({
    audio: false,
    video: {
      width: { ideal: 1280 },
      height: { ideal: 720 },
      facingMode: "user",
    },
  });
  elements.cameraPreview.srcObject = mediaStream;
  elements.cameraStatus.textContent = "Mac camera is live";
  elements.cameraHint.textContent = "Frame one face and follow the guided three-shot enrollment.";
}

function stopCamera() {
  if (!mediaStream) return;
  mediaStream.getTracks().forEach((track) => track.stop());
  mediaStream = null;
  elements.cameraPreview.srcObject = null;
  elements.cameraStatus.textContent = "Camera is idle";
  elements.cameraHint.textContent = "Open the Mac camera, frame one face, then capture the guided shots.";
}

function captureFrameBase64() {
  if (!mediaStream) {
    throw new Error("Start the Mac camera before trying to enroll.");
  }
  const video = elements.cameraPreview;
  const canvas = elements.captureCanvas;
  canvas.width = video.videoWidth || 1280;
  canvas.height = video.videoHeight || 720;
  const context = canvas.getContext("2d");
  context.drawImage(video, 0, 0, canvas.width, canvas.height);
  return canvas.toDataURL("image/jpeg", 0.92);
}

async function enrollSharedTemplate({ imageBase64, source, resetSequence = false }) {
  const personID = activeLivePersonID() ?? selectedStudentID();
  if (!personID) {
    throw new Error("Choose a student before enrollment.");
  }
  if (resetSequence || !enrollmentSequenceID) {
    enrollmentSequenceID = crypto.randomUUID();
    nextShotIndex = 1;
  }
  const shot = shotRoleFor(nextShotIndex);
  const response = await fetchJSON("/v1/demo/control/enroll-from-mac", {
    method: "POST",
    body: JSON.stringify({
      tenant_id: "truepresence-demo",
      person_id: personID,
      image_base64: imageBase64,
      source,
      sequence_id: enrollmentSequenceID,
      shot_index: nextShotIndex,
      shot_role: source === "mac_upload" ? "single_upload" : shot.role,
    }),
  });
  elements.enrollmentCard.innerHTML = `
    <strong>${escapeHTML(response.person.display_name)} enrollment updated.</strong>
    <span>${response.template_count} template(s) · quality ${Number(response.quality_score).toFixed(2)} · detection ${Number(response.detection_score).toFixed(2)}</span>
    <span>Capture ${escapeHTML(response.capture_id ?? "unknown")} saved locally and visible in Finder.</span>
  `;
  if (source === "mac_upload") {
    selectedUploadDataURL = null;
    elements.uploadInput.value = "";
    enrollmentSequenceID = null;
    nextShotIndex = 1;
  } else if (nextShotIndex < guidedShotRoles.length) {
    nextShotIndex += 1;
  } else {
    enrollmentSequenceID = null;
    nextShotIndex = 1;
  }
  renderShotGuide();
  await refreshSnapshot();
}

async function enrollFromCamera() {
  const imageBase64 = captureFrameBase64();
  await enrollSharedTemplate({ imageBase64, source: "mac_camera" });
}

async function enrollFromUpload() {
  if (!selectedUploadDataURL) {
    throw new Error("Choose an image file before uploading.");
  }
  await enrollSharedTemplate({
    imageBase64: selectedUploadDataURL,
    source: "mac_upload",
    resetSequence: true,
  });
}

function readFileAsDataURL(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error ?? new Error("Failed to read the image file."));
    reader.readAsDataURL(file);
  });
}

elements.connectButton.addEventListener("click", () => {
  connectConsole().catch((error) => {
    elements.transportStatus.textContent = "connection failed";
    elements.streamStatus.textContent = "disconnected";
    setLog(error.message);
  });
});

elements.refreshButton.addEventListener("click", () => {
  Promise.all([refreshTenants(), refreshSnapshot()]).catch((error) => {
    elements.transportStatus.textContent = "refresh failed";
    setLog(error.message);
  });
});

elements.fullResetButton.addEventListener("click", () => {
  fullReset().catch((error) => setLog(error.message));
});

elements.clearEventsButton.addEventListener("click", () => {
  clearEvents().catch((error) => setLog(error.message));
});

elements.sessionStartButton.addEventListener("click", () => {
  startSession().catch((error) => setLog(error.message));
});

elements.sessionPersonID.addEventListener("change", () => {
  preferredSessionPersonID = elements.sessionPersonID.value || null;
  latestBindingQR = null;
  renderBindingQRCode(latestBindingQR);
});

elements.addPersonButton.addEventListener("click", () => {
  addPerson().catch((error) => setLog(error.message));
});

elements.generateQRButton.addEventListener("click", () => {
  generateBindingQR().catch((error) => setLog(error.message));
});

elements.startCameraButton.addEventListener("click", () => {
  startCamera().catch((error) => {
    elements.cameraStatus.textContent = "Camera unavailable";
    showEnrollmentError(error.message);
  });
});

elements.stopCameraButton.addEventListener("click", stopCamera);

elements.enrollButton.addEventListener("click", () => {
  enrollFromCamera().catch((error) => showEnrollmentError(error.message));
});

elements.uploadInput.addEventListener("change", async () => {
  const file = elements.uploadInput.files?.[0];
  if (!file) {
    selectedUploadDataURL = null;
    return;
  }
  try {
    selectedUploadDataURL = await readFileAsDataURL(file);
    setLog(`Loaded ${file.name}. Use "Upload & Enroll Fallback" to save it into the active live session.`);
  } catch (error) {
    selectedUploadDataURL = null;
    setLog(error.message);
  }
});

elements.uploadEnrollButton.addEventListener("click", () => {
  enrollFromUpload().catch((error) => showEnrollmentError(error.message));
});

renderShotGuide();
connectConsole().catch((error) => {
  elements.transportStatus.textContent = "connection failed";
  setLog(error.message);
});
