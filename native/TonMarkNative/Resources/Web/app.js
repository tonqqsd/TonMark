const native = window.webkit?.messageHandlers?.native;
const app = document.getElementById('app');
const liveEditor = document.getElementById('live-editor');
const source = document.getElementById('source');
const preview = document.getElementById('preview');
const toast = document.getElementById('toast');
const findPanel = document.getElementById('find-panel');
const findQuery = document.getElementById('find-query');
const replaceQuery = document.getElementById('replace-query');
const findStatus = document.getElementById('find-status');
const findPrevButton = document.getElementById('find-prev');
const findNextButton = document.getElementById('find-next');
const replaceOneButton = document.getElementById('replace-one');
const replaceAllButton = document.getElementById('replace-all');
const findCloseButton = document.getElementById('find-close');
const outlinePanel = document.getElementById('outline-panel');
const outlineQuery = document.getElementById('outline-query');
const outlineList = document.getElementById('outline-list');
const outlineStatus = document.getElementById('outline-status');
const outlineCloseButton = document.getElementById('outline-close');
const settingsPanel = document.getElementById('settings-panel');
const settingsTheme = document.getElementById('settings-theme');
const settingsFontSize = document.getElementById('settings-font-size');
const settingsFontSizeValue = document.getElementById('settings-font-size-value');
const settingsLineHeight = document.getElementById('settings-line-height');
const settingsLineHeightValue = document.getElementById('settings-line-height-value');
const settingsWidth = document.getElementById('settings-width');
const settingsFocusMode = document.getElementById('settings-focus-mode');
const settingsTypewriterMode = document.getElementById('settings-typewriter-mode');
const settingsCloseButton = document.getElementById('settings-close');
const settingsResetButton = document.getElementById('settings-reset');
const recoveryBanner = document.getElementById('recovery-banner');
const recoveryText = document.getElementById('recovery-text');
const restoreDraftButton = document.getElementById('restore-draft');
const discardDraftButton = document.getElementById('discard-draft');
const statusMode = document.getElementById('status-mode');
const statusCount = document.getElementById('status-count');
const statusPosition = document.getElementById('status-position');
const statusSave = document.getElementById('status-save');

let currentName = 'Untitled.md';
let currentPath = '';
let currentBasePath = '';
let dirty = false;
let documentRevision = 0;
let blocks = [];
let activeBlockId = null;
let nextBlockId = 1;
let mermaidPromise = null;
let mermaidRenderCount = 0;
let contextMenu = null;
let pendingTableFocus = null;
let isRenderingExportHTML = false;
let findState = {
  query: '',
  replacement: '',
  matches: [],
  index: -1,
  replaceMode: false
};
let outlineState = {
  headings: [],
  filtered: [],
  index: -1
};
let draftTimer = null;
let pendingDraft = null;
let typewriterFrame = 0;
let statusBarFrame = 0;
let statusStatsRevision = -1;
let statusStatsCache = { characters: 0, words: 0 };
let previewRenderTimer = null;

const draftKey = 'tonmark.draft.v1';
const preferenceKey = 'tonmark.preferences.v1';
const defaultPreferences = {
  theme: 'system',
  fontSize: 16,
  lineHeight: 1.72,
  width: 'normal',
  focusMode: false,
  typewriterMode: false
};

const starter = `# Untitled

开始写作。`;

let editorPreferences = readEditorPreferences();
applyEditorPreferences(editorPreferences);
setDocument('Untitled.md', '', starter);
window.setTimeout(checkRecoverableDraft, 0);
window.matchMedia?.('(prefers-color-scheme: dark)').addEventListener?.('change', () => {
  if (editorPreferences.theme === 'system') {
    post('themeChanged', { theme: effectiveEditorTheme() });
  }
});

function post(type, payload = {}) {
  native?.postMessage({ type, ...payload });
}

function readEditorPreferences() {
  try {
    return normalizeEditorPreferences(JSON.parse(localStorage.getItem(preferenceKey) || 'null'));
  } catch {
    return { ...defaultPreferences };
  }
}

function normalizeEditorPreferences(value = {}) {
  const next = { ...defaultPreferences, ...(value || {}) };
  const themes = new Set(['system', 'light', 'dark', 'sepia']);
  const widths = new Set(['narrow', 'normal', 'wide', 'full']);
  next.theme = themes.has(next.theme) ? next.theme : defaultPreferences.theme;
  next.width = widths.has(next.width) ? next.width : defaultPreferences.width;
  next.fontSize = clamp(Number(next.fontSize) || defaultPreferences.fontSize, 14, 22);
  next.lineHeight = clamp(Number(next.lineHeight) || defaultPreferences.lineHeight, 1.4, 2);
  next.focusMode = Boolean(next.focusMode);
  next.typewriterMode = Boolean(next.typewriterMode);
  return next;
}

function saveEditorPreferences() {
  try {
    localStorage.setItem(preferenceKey, JSON.stringify(editorPreferences));
  } catch {
    showToast('设置保存失败');
  }
}

function applyEditorPreferences(preferences) {
  editorPreferences = normalizeEditorPreferences(preferences);
  if (editorPreferences.theme === 'system') {
    document.body.removeAttribute('data-theme');
  } else {
    document.body.dataset.theme = editorPreferences.theme;
  }
  document.body.dataset.width = editorPreferences.width;
  document.body.classList.toggle('focus-mode', editorPreferences.focusMode);
  document.body.classList.toggle('typewriter-mode', editorPreferences.typewriterMode);
  document.documentElement.style.setProperty('--editor-font-size', `${editorPreferences.fontSize}px`);
  document.documentElement.style.setProperty('--editor-line-height', editorPreferences.lineHeight.toFixed(2));
  syncSettingsControls();
  scheduleTypewriterScroll();
  post('themeChanged', { theme: effectiveEditorTheme() });
}

function effectiveEditorTheme() {
  if (editorPreferences.theme === 'system') {
    return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  return editorPreferences.theme;
}

function updateEditorPreferences(patch) {
  applyEditorPreferences({ ...editorPreferences, ...patch });
  saveEditorPreferences();
  updateStatusBar();
}

function syncSettingsControls() {
  if (!settingsPanel) return;
  settingsTheme.value = editorPreferences.theme;
  settingsFontSize.value = String(editorPreferences.fontSize);
  settingsFontSizeValue.textContent = `${editorPreferences.fontSize}px`;
  settingsLineHeight.value = editorPreferences.lineHeight.toFixed(2);
  settingsLineHeightValue.textContent = editorPreferences.lineHeight.toFixed(2);
  settingsWidth.value = editorPreferences.width;
  settingsFocusMode.checked = editorPreferences.focusMode;
  settingsTypewriterMode.checked = editorPreferences.typewriterMode;
}

function showSettings() {
  hideContextMenu();
  hideOutline();
  syncSettingsControls();
  settingsPanel.hidden = false;
  window.setTimeout(() => settingsTheme.focus(), 0);
}

function hideSettings() {
  settingsPanel.hidden = true;
}

function resetEditorPreferences() {
  updateEditorPreferences({ ...defaultPreferences });
  showToast('已恢复默认设置');
}

function toggleFocusMode() {
  updateEditorPreferences({ focusMode: !editorPreferences.focusMode });
  showToast(editorPreferences.focusMode ? '已开启专注模式' : '已关闭专注模式');
}

function toggleTypewriterMode() {
  updateEditorPreferences({ typewriterMode: !editorPreferences.typewriterMode });
  showToast(editorPreferences.typewriterMode ? '已开启打字机模式' : '已关闭打字机模式');
}

function setEditorTheme(theme) {
  const labels = {
    system: '跟随系统',
    light: '浅色',
    dark: '深色',
    sepia: '暖纸'
  };
  const nextTheme = labels[theme] ? theme : defaultPreferences.theme;
  updateEditorPreferences({ theme: nextTheme });
  showToast(`主题：${labels[nextTheme]}`);
}

function adjustEditorFontSize(delta) {
  const nextSize = clamp(editorPreferences.fontSize + Number(delta || 0), 14, 22);
  updateEditorPreferences({ fontSize: nextSize });
  showToast(`字体大小：${nextSize}px`);
}

function adjustEditorLineHeight(delta) {
  const nextLineHeight = Number(clamp(editorPreferences.lineHeight + Number(delta || 0), 1.4, 2).toFixed(2));
  updateEditorPreferences({ lineHeight: nextLineHeight });
  showToast(`行高：${nextLineHeight.toFixed(2)}`);
}

function resetEditorTypography() {
  updateEditorPreferences({
    fontSize: defaultPreferences.fontSize,
    lineHeight: defaultPreferences.lineHeight
  });
  showToast('已恢复默认字号和行高');
}

function makeBlock(raw) {
  return {
    id: `b${nextBlockId++}`,
    raw
  };
}

function setDirty(value) {
  if (value) {
    documentRevision += 1;
  }
  dirty = value;
  document.body.classList.toggle('dirty', dirty);
  post('dirtyChanged', { dirty });
  updateStatusBar();
  if (dirty) scheduleDraftSave();
}

function setDocument(name, path, content, basePath = '', options = {}) {
  hideOutline();
  currentName = name || 'Untitled.md';
  currentPath = path || '';
  currentBasePath = basePath || pathToDirectory(currentPath);
  source.value = content ?? '';
  blocks = parseBlocks(source.value);
  activeBlockId = blocks[0]?.id ?? null;
  documentRevision += 1;
  setDirty(Boolean(options.dirty));
  renderLiveEditor();
  renderPreview();
  refreshFindIfOpen();
  updateStatusBar();
  window.setTimeout(() => focusBlock(activeBlockId, 'end'), 0);
}

function setBasePath(path) {
  currentBasePath = path || '';
}

function pathToDirectory(path) {
  if (!path || !path.includes('/')) return '';
  return path.slice(0, path.lastIndexOf('/'));
}

function scheduleDraftSave() {
  window.clearTimeout(draftTimer);
  draftTimer = window.setTimeout(saveDraftNow, 650);
}

function saveDraftNow() {
  window.clearTimeout(draftTimer);
  draftTimer = null;
  if (!dirty) return;

  try {
    localStorage.setItem(draftKey, JSON.stringify({
      name: currentName,
      path: currentPath,
      basePath: currentBasePath,
      content: getMarkdown(),
      dirty: true,
      savedAt: Date.now()
    }));
  } catch {
    showToast('草稿保存失败');
  }
}

function readDraft() {
  try {
    const draft = JSON.parse(localStorage.getItem(draftKey) || 'null');
    if (!draft || typeof draft.content !== 'string') return null;
    if (!draft.content.trim() || draft.content.trim() === starter.trim()) return null;
    return draft;
  } catch {
    return null;
  }
}

function clearDraft() {
  window.clearTimeout(draftTimer);
  draftTimer = null;
  pendingDraft = null;
  localStorage.removeItem(draftKey);
  recoveryBanner.hidden = true;
}

function checkRecoverableDraft() {
  const draft = readDraft();
  if (!draft?.dirty) return;

  pendingDraft = draft;
  const name = draft.name || (draft.path ? draft.path.split('/').pop() : '未命名文档');
  const time = draft.savedAt ? `，${formatDraftTime(draft.savedAt)}` : '';
  recoveryText.textContent = `${name} 有未保存草稿${time}`;
  recoveryBanner.hidden = false;
}

function restoreDraft() {
  const draft = pendingDraft || readDraft();
  if (!draft) {
    clearDraft();
    return;
  }

  recoveryBanner.hidden = true;
  setDocument(
    draft.name || 'Recovered.md',
    draft.path || '',
    draft.content || '',
    draft.basePath || '',
    { dirty: true }
  );
  post('draftRestored', {
    name: draft.name || 'Recovered.md',
    path: draft.path || '',
    basePath: draft.basePath || ''
  });
  showToast('已恢复草稿');
}

function discardDraft() {
  clearDraft();
  showToast('已忽略草稿');
}

function formatDraftTime(timestamp) {
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleString('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  });
}

function parseBlocks(markdown) {
  const normalized = String(markdown || '').replace(/\r\n/g, '\n');
  const lines = normalized.split('\n');
  const parsed = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (line.trim() === '') {
      while (i < lines.length && lines[i].trim() === '') i += 1;
      continue;
    }

    if (/^```/.test(line.trim())) {
      const group = [line];
      i += 1;
      while (i < lines.length) {
        group.push(lines[i]);
        if (/^```/.test(lines[i].trim())) {
          i += 1;
          break;
        }
        i += 1;
      }
      parsed.push(makeBlock(group.join('\n')));
      continue;
    }

    if (isTableStart(lines, i)) {
      const group = [];
      while (i < lines.length && lines[i].includes('|') && lines[i].trim() !== '') {
        group.push(lines[i]);
        i += 1;
      }
      parsed.push(makeBlock(group.join('\n')));
      continue;
    }

    if (isListLine(line)) {
      const group = [];
      while (i < lines.length && (isListLine(lines[i]) || /^\s{2,}\S/.test(lines[i]) || lines[i].trim() === '')) {
        if (lines[i].trim() === '' && !isListLine(lines[i + 1] || '')) break;
        group.push(lines[i]);
        i += 1;
      }
      parsed.push(makeBlock(group.join('\n')));
      continue;
    }

    if (/^>\s?/.test(line)) {
      const group = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        group.push(lines[i]);
        i += 1;
      }
      parsed.push(makeBlock(group.join('\n')));
      continue;
    }

    if (/^(#{1,6})\s+/.test(line) || /^-{3,}$/.test(line.trim()) || /^\*{3,}$/.test(line.trim())) {
      parsed.push(makeBlock(line));
      i += 1;
      continue;
    }

    const group = [];
    while (
      i < lines.length &&
      lines[i].trim() !== '' &&
      !/^```/.test(lines[i].trim()) &&
      !isTableStart(lines, i) &&
      !isListLine(lines[i]) &&
      !/^>\s?/.test(lines[i]) &&
      !/^(#{1,6})\s+/.test(lines[i]) &&
      !/^-{3,}$/.test(lines[i].trim()) &&
      !/^\*{3,}$/.test(lines[i].trim())
    ) {
      group.push(lines[i]);
      i += 1;
    }
    parsed.push(makeBlock(group.join('\n')));
  }

  return parsed.length ? parsed : [makeBlock('')];
}

function getMarkdown() {
  if (app.classList.contains('mode-source')) {
    return source.value.replace(/\r\n/g, '\n').trimEnd();
  }

  syncActiveBlock();
  return composeMarkdown();
}

function composeMarkdown() {
  return blocks.map((block) => block.raw).join('\n\n').replace(/\n{4,}/g, '\n\n\n').trimEnd();
}

function renderLiveEditor(preserveCaret = false) {
  const previousCaret = preserveCaret ? getCaretOffset(activeElement()) : null;
  const existingById = new Map([...liveEditor.children].map((element) => [element.dataset.id, element]));
  const fragment = document.createDocumentFragment();
  const changedElements = [];

  blocks.forEach((block) => {
    const type = blockType(block.raw);
    const isActive = block.id === activeBlockId;
    const existing = existingById.get(block.id);
    let element = existing;
    if (!canReuseLiveBlock(existing, block, type, isActive)) {
      element = createLiveBlockElement(block, type, isActive);
      changedElements.push(element);
    }

    fragment.appendChild(element);
  });

  liveEditor.replaceChildren(fragment);

  if (preserveCaret && previousCaret !== null) {
    focusBlock(activeBlockId, previousCaret);
  } else if (pendingTableFocus) {
    const focus = pendingTableFocus;
    pendingTableFocus = null;
    window.setTimeout(() => focusTableCell(focus.blockId, focus.section, focus.row, focus.col), 0);
  }

  changedElements.forEach((element) => hydrateRichContent(element));
  paintFindHighlights(liveEditor);
  scheduleTypewriterScroll();
}

function canReuseLiveBlock(element, block, type, isActive) {
  return Boolean(
    element &&
    element.__tonmarkRaw === block.raw &&
    element.dataset.type === type &&
    element.dataset.active === String(isActive)
  );
}

function createLiveBlockElement(block, type, isActive) {
  const element = document.createElement('section');
  element.className = `tm-block tm-${type}`;
  element.dataset.id = block.id;
  element.dataset.type = type;
  element.dataset.active = String(isActive);
  element.__tonmarkRaw = block.raw;

  if (isActive && type === 'table') {
    element.classList.add('is-editing', 'table-editing');
    renderEditableTable(block, element);
  } else if (isActive) {
    element.classList.add('is-editing');
    element.contentEditable = 'true';
    element.spellcheck = true;
    element.textContent = block.raw;
    element.addEventListener('input', handleBlockInput);
    element.addEventListener('keydown', handleBlockKeydown);
    element.addEventListener('paste', handlePaste);
    element.addEventListener('blur', handleBlockBlur);
  } else {
    element.tabIndex = 0;
    element.innerHTML = renderBlock(block.raw, type);
  }

  element.addEventListener('mousedown', (event) => {
    if (event.button !== 0 || block.id === activeBlockId) return;
    event.preventDefault();
    syncActiveBlock();
    activeBlockId = block.id;
    renderLiveEditor();
    window.setTimeout(() => {
      if (type === 'table') {
        focusTableCell(block.id, 'body', 0, 0);
      } else {
        focusBlock(block.id, 'end');
      }
    }, 0);
  });

  return element;
}

function renderPreview() {
  window.clearTimeout(previewRenderTimer);
  previewRenderTimer = null;
  preview.innerHTML = markdownToHtml(getMarkdown());
  hydrateRichContent(preview);
  paintFindHighlights(preview);
}

function schedulePreviewRender() {
  window.clearTimeout(previewRenderTimer);
  if (currentMode() === 'mode-preview' || document.body.classList.contains('is-print-export')) {
    renderPreview();
    return;
  }

  previewRenderTimer = window.setTimeout(() => {
    previewRenderTimer = null;
    renderPreview();
  }, 160);
}

function flushPreviewRender() {
  renderPreview();
}

function renderEditableTable(block, element) {
  const model = parseTable(block.raw);
  const wrap = document.createElement('div');
  const table = document.createElement('table');

  wrap.className = 'visual-table-wrap';
  table.className = 'visual-table';
  table.dataset.blockId = block.id;

  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  model.headers.forEach((cell, col) => {
    const th = editableTableCell('th', cell, 'head', 0, col, model.aligns[col]);
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);

  const tbody = document.createElement('tbody');
  model.rows.forEach((row, rowIndex) => {
    const tr = document.createElement('tr');
    row.forEach((cell, col) => {
      tr.appendChild(editableTableCell('td', cell, 'body', rowIndex, col, model.aligns[col]));
    });
    tbody.appendChild(tr);
  });

  table.appendChild(thead);
  table.appendChild(tbody);
  wrap.appendChild(table);
  element.appendChild(wrap);

  element.addEventListener('input', handleTableInput);
  element.addEventListener('keydown', handleTableKeydown);
  element.addEventListener('paste', handlePaste);
  element.addEventListener('focusout', handleTableFocusOut);
}

function editableTableCell(tag, value, section, row, col, align) {
  const cell = document.createElement(tag);
  cell.contentEditable = 'true';
  cell.spellcheck = true;
  cell.className = 'table-cell';
  cell.dataset.section = section;
  cell.dataset.row = String(row);
  cell.dataset.col = String(col);
  cell.dataset.align = align || '';
  if (align) cell.style.textAlign = align;
  cell.textContent = value;
  return cell;
}

function handleTableInput(event) {
  const blockEl = event.currentTarget;
  updateTableBlockFromElement(blockEl.dataset.id);
}

function handleTableFocusOut() {
  window.setTimeout(() => {
    if (!liveEditor.contains(document.activeElement)) {
      syncActiveBlock();
      renderLiveEditor();
      renderPreview();
    }
  }, 0);
}

function handleTableKeydown(event) {
  if (event.metaKey && event.key.toLowerCase() === 's') {
    event.preventDefault();
    window.TonMark.commands.save();
    return;
  }

  if (event.metaKey && event.key.toLowerCase() === 'b') {
    event.preventDefault();
    wrapSelection('**');
    return;
  }

  if (event.metaKey && event.key.toLowerCase() === 'i') {
    event.preventDefault();
    wrapSelection('*');
    return;
  }

  const cell = event.target.closest('.table-cell');
  if (!cell) return;

  if (event.key === 'Tab') {
    event.preventDefault();
    moveTableFocus(cell, event.shiftKey ? -1 : 1);
    return;
  }

  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    moveTableFocus(cell, 1, true);
  }
}

function moveTableFocus(cell, delta, vertical = false) {
  const blockEl = cell.closest('.tm-block');
  if (!blockEl) return;

  updateTableBlockFromElement(blockEl.dataset.id);

  const model = parseTable(blocks.find((block) => block.id === blockEl.dataset.id)?.raw || '');
  const section = cell.dataset.section;
  const row = Number(cell.dataset.row || 0);
  const col = Number(cell.dataset.col || 0);
  const columns = Math.max(1, model.headers.length);

  let nextSection = section;
  let nextRow = row;
  let nextCol = col;

  if (vertical) {
    nextSection = 'body';
    nextRow = section === 'head' ? 0 : row + 1;
    if (nextRow >= model.rows.length) {
      model.rows.push(Array.from({ length: columns }, () => ''));
      setTableBlockRaw(blockEl.dataset.id, serializeTable(model));
    }
  } else {
    const flat = tableCellToFlatIndex(section, row, col, columns) + delta;
    const max = columns * (model.rows.length + 1);
    if (flat >= max) {
      model.rows.push(Array.from({ length: columns }, () => ''));
      setTableBlockRaw(blockEl.dataset.id, serializeTable(model));
      nextSection = 'body';
      nextRow = model.rows.length - 1;
      nextCol = 0;
    } else {
      const next = flatToTableCell(Math.max(0, flat), columns);
      nextSection = next.section;
      nextRow = next.row;
      nextCol = next.col;
    }
  }

  pendingTableFocus = { blockId: blockEl.dataset.id, section: nextSection, row: nextRow, col: nextCol };
  renderLiveEditor();
}

function tableCellToFlatIndex(section, row, col, columns) {
  return section === 'head' ? col : columns + row * columns + col;
}

function flatToTableCell(index, columns) {
  if (index < columns) return { section: 'head', row: 0, col: index };
  const bodyIndex = index - columns;
  return {
    section: 'body',
    row: Math.floor(bodyIndex / columns),
    col: bodyIndex % columns
  };
}

function focusTableCell(blockId, section, row, col) {
  const selector = `[data-id="${blockId}"] .table-cell[data-section="${section}"][data-row="${row}"][data-col="${col}"]`;
  const cell = liveEditor.querySelector(selector) || liveEditor.querySelector(`[data-id="${blockId}"] .table-cell`);
  if (!cell) return;
  cell.focus();
  setCaretOffset(cell, cell.textContent.length);
  scheduleTypewriterScroll();
}

function updateTableBlockFromElement(blockId) {
  const blockEl = liveEditor.querySelector(`[data-id="${blockId}"]`);
  if (!blockEl) return;
  setTableBlockRaw(blockId, serializeTable(readTableFromElement(blockEl)));
  source.value = composeMarkdown();
  setDirty(true);
  refreshFindIfOpen();
}

function setTableBlockRaw(blockId, raw) {
  const block = blocks.find((item) => item.id === blockId);
  if (!block) return;
  block.raw = raw;
}

function activeElement() {
  return activeBlockId ? liveEditor.querySelector(`[data-id="${activeBlockId}"]`) : null;
}

function activeIndex() {
  return blocks.findIndex((block) => block.id === activeBlockId);
}

function focusBlock(id, position = 'end') {
  const element = id ? liveEditor.querySelector(`[data-id="${id}"]`) : null;
  if (!element) return;
  element.focus();
  if (position === 'click') {
    scheduleTypewriterScroll();
    return;
  }
  const offset = position === 'start' ? 0 : position === 'end' ? element.textContent.length : position;
  setCaretOffset(element, offset);
  scheduleTypewriterScroll();
}

function scheduleTypewriterScroll() {
  if (!editorPreferences.typewriterMode || !app.classList.contains('mode-live')) return;

  window.cancelAnimationFrame(typewriterFrame);
  typewriterFrame = window.requestAnimationFrame(() => {
    typewriterFrame = 0;
    centerActiveWritingTarget();
  });
}

function centerActiveWritingTarget() {
  if (!editorPreferences.typewriterMode || !app.classList.contains('mode-live')) return;

  const target = document.activeElement?.closest?.('.table-cell') || activeElement();
  if (!target) return;

  const writer = document.querySelector('.writer');
  if (!writer) return;
  const targetRect = target.getBoundingClientRect();
  const writerRect = writer.getBoundingClientRect();
  const targetCenter = targetRect.top + targetRect.height / 2;
  const writerCenter = writerRect.top + writer.clientHeight * 0.45;
  writer.scrollTop += targetCenter - writerCenter;
}

function syncActiveBlock() {
  const element = activeElement();
  const index = activeIndex();
  if (!element || index < 0) return;

  if (element.dataset.type === 'table') {
    blocks[index].raw = serializeTable(readTableFromElement(element));
    return;
  }

  if (!element.isContentEditable) return;
  blocks[index].raw = normalizeEditableText(element.innerText);
}

function normalizeEditableText(value) {
  return String(value || '')
    .replace(/\u00a0/g, ' ')
    .replace(/\r\n/g, '\n')
    .replace(/\n$/g, '');
}

function handleBlockInput(event) {
  const index = blocks.findIndex((block) => block.id === event.currentTarget.dataset.id);
  if (index < 0) return;
  blocks[index].raw = normalizeEditableText(event.currentTarget.innerText);
  source.value = getMarkdown();
  setDirty(true);
  refreshFindIfOpen();
  scheduleTypewriterScroll();
}

function handleBlockBlur() {
  syncActiveBlock();
  window.setTimeout(() => {
    if (!liveEditor.contains(document.activeElement)) {
      renderLiveEditor();
      schedulePreviewRender();
    }
  }, 0);
}

function handlePaste(event) {
  const imageItems = [...(event.clipboardData?.items || [])].filter((item) => item.type.startsWith('image/'));
  if (imageItems.length) {
    event.preventDefault();
    imageItems.forEach((item, index) => {
      const file = item.getAsFile();
      if (file) importImageFile(file, `pasted-image-${index + 1}.png`);
    });
    return;
  }

  event.preventDefault();
  const text = event.clipboardData?.getData('text/plain') ?? '';
  document.execCommand('insertText', false, text);
}

function handleBlockKeydown(event) {
  if (event.metaKey && event.key.toLowerCase() === 's') {
    event.preventDefault();
    window.TonMark.commands.save();
    return;
  }

  if (event.metaKey && event.key.toLowerCase() === 'b') {
    event.preventDefault();
    wrapSelection('**');
    return;
  }

  if (event.metaKey && event.key.toLowerCase() === 'i') {
    event.preventDefault();
    wrapSelection('*');
    return;
  }

  if (event.key === 'Tab') {
    event.preventDefault();
    document.execCommand('insertText', false, '  ');
    return;
  }

  if (event.key === 'Enter' && !event.shiftKey) {
    const index = activeIndex();
    const element = activeElement();
    if (index < 0 || !element) return;

    if (blockType(blocks[index].raw) === 'code' && !event.metaKey) {
      return;
    }

    event.preventDefault();
    splitBlockAtCaret(index, element);
    return;
  }

  if (event.key === 'Backspace') {
    const index = activeIndex();
    const element = activeElement();
    if (index > 0 && element && normalizeEditableText(element.innerText) === '') {
      event.preventDefault();
      blocks.splice(index, 1);
      activeBlockId = blocks[index - 1].id;
      setDirty(true);
      renderLiveEditor();
      refreshFindIfOpen();
      focusBlock(activeBlockId, 'end');
    }
  }
}

function splitBlockAtCaret(index, element) {
  syncActiveBlock();
  const raw = blocks[index].raw;
  const caret = getCaretOffset(element);
  const before = raw.slice(0, caret).replace(/\s+$/g, '');
  const after = raw.slice(caret).replace(/^\s+/g, '');

  if (!after && isEmptyListSeed(raw)) {
    blocks[index].raw = '';
    source.value = getMarkdown();
    setDirty(true);
    renderLiveEditor();
    refreshFindIfOpen();
    focusBlock(activeBlockId, 'end');
    return;
  }

  const nextRaw = after || nextBlockSeed(raw);

  blocks[index].raw = before;
  const nextBlock = makeBlock(nextRaw);
  blocks.splice(index + 1, 0, nextBlock);
  activeBlockId = nextBlock.id;
  source.value = getMarkdown();
  setDirty(true);
  renderLiveEditor();
  refreshFindIfOpen();
  focusBlock(activeBlockId, after ? 'start' : 'end');
}

function nextBlockSeed(raw) {
  const list = raw.match(/^(\s*)([-*+])\s+/);
  if (list) return `${list[1]}${list[2]} `;
  const ordered = raw.match(/^(\s*)(\d+)\.\s+/);
  if (ordered) return `${ordered[1]}${Number(ordered[2]) + 1}. `;
  const quote = raw.match(/^>\s?/);
  if (quote) return '> ';
  return '';
}

function wrapSelection(marker) {
  const selection = window.getSelection();
  const element = activeElement();
  if (!selection || !element || selection.rangeCount === 0 || !element.contains(selection.anchorNode)) return;

  const text = selection.toString();
  document.execCommand('insertText', false, `${marker}${text || '文本'}${marker}`);
}

function getCaretOffset(element) {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0 || !element || !element.contains(selection.anchorNode)) {
    return element?.textContent.length ?? 0;
  }

  const range = selection.getRangeAt(0);
  const preCaret = range.cloneRange();
  preCaret.selectNodeContents(element);
  preCaret.setEnd(range.endContainer, range.endOffset);
  return preCaret.toString().length;
}

function setCaretOffset(element, offset) {
  const target = Math.max(0, Math.min(offset, element.textContent.length));
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let current = 0;
  let node = walker.nextNode();

  while (node) {
    const next = current + node.nodeValue.length;
    if (target <= next) {
      const range = document.createRange();
      range.setStart(node, target - current);
      range.collapse(true);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      return;
    }
    current = next;
    node = walker.nextNode();
  }

  const range = document.createRange();
  range.selectNodeContents(element);
  range.collapse(false);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

function blockType(raw) {
  const trimmed = raw.trim();
  if (!trimmed) return 'empty';
  if (isMathBlock(raw)) return 'math';
  if (/^```/.test(trimmed)) return 'code';
  if (isTableStart(trimmed.split('\n'), 0)) return 'table';
  if (/^(#{1,6})\s+/.test(trimmed)) return 'heading';
  if (/^>\s?/.test(trimmed)) return 'quote';
  if (/^(\s*[-*+]|\s*\d+\.)\s+/.test(raw)) return 'list';
  if (/^(-{3,}|\*{3,})$/.test(trimmed)) return 'rule';
  return 'paragraph';
}

function renderBlock(raw, type) {
  if (type === 'empty') return '<p class="empty-line"><br></p>';

  if (type === 'heading') {
    const match = raw.trim().match(/^(#{1,6})\s+(.+)$/);
    const level = Math.min(match?.[1].length ?? 1, 6);
    return `<h${level}>${inline(match?.[2] ?? '')}</h${level}>`;
  }

  if (type === 'math') {
    const math = mathBlockSource(raw);
    return `<div class="math-block" data-math="${escapeAttribute(math)}"><pre>${escapeHtml(math)}</pre></div>`;
  }

  if (type === 'code') {
    const lines = raw.split('\n');
    const language = lines[0].replace(/^```/, '').trim();
    const lastLine = lines[lines.length - 1] || '';
    const body = lines.slice(1, lastLine.trim().startsWith('```') ? -1 : undefined).join('\n');

    if (language.toLowerCase() === 'mermaid') {
      return `<div class="mermaid-block" data-mermaid="${escapeAttribute(body)}"><pre><code>${escapeHtml(body)}</code></pre></div>`;
    }

    return `<pre data-language="${escapeAttribute(language)}"><code>${escapeHtml(body)}</code></pre>`;
  }

  if (type === 'table') {
    return tableToHtml(raw);
  }

  if (type === 'quote') {
    const body = raw.split('\n').map((line) => line.replace(/^>\s?/, '')).join('\n');
    return `<blockquote>${inline(body).replace(/\n/g, '<br>')}</blockquote>`;
  }

  if (type === 'list') {
    const ordered = /^\s*\d+\.\s+/.test(raw);
    const tag = ordered ? 'ol' : 'ul';
    const lines = raw.split('\n').filter((line) => line.trim());
    const items = lines.map((line) => `<li>${inline(line.replace(/^\s*(?:[-*+]|\d+\.)\s+/, ''))}</li>`).join('');
    return `<${tag}>${items}</${tag}>`;
  }

  if (type === 'rule') {
    return '<hr>';
  }

  return `<p>${inline(raw).replace(/\n/g, '<br>')}</p>`;
}

function markdownToHtml(markdown) {
  return parseBlocks(markdown).map((block) => renderBlock(block.raw, blockType(block.raw))).join('\n');
}

function isListLine(line) {
  return /^(\s*[-*+]|\s*\d+\.)\s+/.test(line || '');
}

function isEmptyListSeed(raw) {
  return /^(\s*[-*+]\s*|\s*\d+\.\s*)$/.test(raw || '');
}

function isMathBlock(raw) {
  const trimmed = (raw || '').trim();
  return (/^\$\$/.test(trimmed) && /\$\$$/.test(trimmed) && trimmed.length >= 4) ||
    (/^\\\[/.test(trimmed) && /\\\]$/.test(trimmed));
}

function mathBlockSource(raw) {
  const trimmed = (raw || '').trim();
  if (trimmed.startsWith('$$')) return trimmed.replace(/^\$\$[ \t]*/, '').replace(/[ \t]*\$\$$/, '').trim();
  return trimmed.replace(/^\\\[[ \t]*/, '').replace(/[ \t]*\\\]$/, '').trim();
}

function isTableStart(lines, index) {
  const current = lines[index] || '';
  const next = lines[index + 1] || '';
  return current.includes('|') && /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(next);
}

function tableToHtml(markdown) {
  const model = parseTable(markdown);
  if (!model.headers.length) return `<p>${inline(markdown)}</p>`;

  const head = model.headers.map((cell, col) => {
    const align = model.aligns[col] ? ` style="text-align:${model.aligns[col]}"` : '';
    return `<th data-col="${col}"${align}>${inline(cell)}</th>`;
  }).join('');
  const body = model.rows.map((row, rowIndex) => `<tr>${row.map((cell, col) => {
    const align = model.aligns[col] ? ` style="text-align:${model.aligns[col]}"` : '';
    return `<td data-row="${rowIndex}" data-col="${col}"${align}>${inline(cell)}</td>`;
  }).join('')}</tr>`).join('');
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function parseTable(markdown) {
  const lines = String(markdown || '').split('\n').filter((line) => line.trim());
  if (lines.length < 2) {
    return {
      headers: [],
      aligns: [],
      rows: []
    };
  }

  const rawRows = lines.map(splitTableRow);
  const columnCount = Math.max(1, ...rawRows.map((row) => row.length));
  const headers = normalizeTableRow(rawRows[0], columnCount);
  const aligns = normalizeTableRow(rawRows[1], columnCount).map(tableAlignFromSeparator);
  const rows = rawRows.slice(2).map((row) => normalizeTableRow(row, columnCount));

  return {
    headers,
    aligns,
    rows: rows.length ? rows : [Array.from({ length: columnCount }, () => '')]
  };
}

function readTableFromElement(blockEl) {
  const headers = [...blockEl.querySelectorAll('thead .table-cell')].map((cell) => normalizeTableCell(cell.innerText));
  const aligns = [...blockEl.querySelectorAll('thead .table-cell')].map((cell) => cell.dataset.align || '');
  const rows = [...blockEl.querySelectorAll('tbody tr')].map((row) =>
    [...row.querySelectorAll('.table-cell')].map((cell) => normalizeTableCell(cell.innerText))
  );

  return {
    headers,
    aligns,
    rows: rows.length ? rows : [Array.from({ length: headers.length }, () => '')]
  };
}

function serializeTable(model) {
  const columnCount = Math.max(1, model.headers.length, ...model.rows.map((row) => row.length));
  const headers = normalizeTableRow(model.headers, columnCount);
  const aligns = normalizeTableRow(model.aligns, columnCount);
  const rows = model.rows.length ? model.rows : [Array.from({ length: columnCount }, () => '')];
  const separator = aligns.map(tableSeparatorForAlign);
  const output = [headers, separator, ...rows.map((row) => normalizeTableRow(row, columnCount))];
  return output.map((row) => `| ${row.map(escapeTableCell).join(' | ')} |`).join('\n');
}

function normalizeTableRow(row, columnCount) {
  return Array.from({ length: columnCount }, (_, index) => row[index] ?? '');
}

function normalizeTableCell(value) {
  return String(value || '').replace(/\u00a0/g, ' ').replace(/\n+/g, '<br>').trim();
}

function tableAlignFromSeparator(value) {
  const trimmed = String(value || '').trim();
  if (/^:-{3,}:$/.test(trimmed)) return 'center';
  if (/^-{3,}:$/.test(trimmed)) return 'right';
  if (/^:-{3,}$/.test(trimmed)) return 'left';
  return '';
}

function tableSeparatorForAlign(align) {
  if (align === 'center') return ':---:';
  if (align === 'right') return '---:';
  if (align === 'left') return ':---';
  return '---';
}

function escapeTableCell(value) {
  return String(value || '').replace(/\|/g, '\\|');
}

function splitTableRow(line) {
  return line.replace(/^\s*\||\|\s*$/g, '').split(/(?<!\\)\|/).map((cell) => cell.replace(/\\\|/g, '|').trim());
}

function inline(text) {
  return escapeHtml(text)
    .replace(/\\\((.+?)\\\)/g, (_, math) => mathInline(math))
    .replace(/(^|[^$])\$([^$\n]+)\$/g, (_, prefix, math) => `${prefix}${mathInline(math)}`)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>')
    .replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (_, alt, src) => `<img alt="${escapeAttribute(alt)}" src="${escapeAttribute(resolveAssetURL(src))}">`)
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
      const safeHref = safeLinkHref(href);
      return safeHref ? `<a href="${escapeAttribute(safeHref)}" rel="noopener noreferrer">${label}</a>` : label;
    });
}

function mathInline(math) {
  return `<span class="math-inline" data-math="${escapeAttribute(math)}">${escapeHtml(math)}</span>`;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function escapeAttribute(value) {
  return escapeHtml(value).replace(/'/g, '&#39;');
}

function resolveAssetURL(src) {
  const clean = String(src || '').trim().replace(/^<|>$/g, '');
  if (/^(https?:|data:|file:|blob:)/i.test(clean)) return clean;
  if (clean.startsWith('/')) return localAssetURL(clean);
  if (!currentBasePath) return clean;
  return localAssetURL(`${currentBasePath}/${clean}`);
}

function localAssetURL(path) {
  if (isRenderingExportHTML) return `file://${encodeURI(path)}`;
  return `tonmark-asset://local?path=${encodeURIComponent(path)}`;
}

function safeLinkHref(href) {
  const clean = String(href || '').trim().replace(/^<|>$/g, '');
  if (!clean) return '';
  if (/^(https?:|mailto:)/i.test(clean) || clean.startsWith('#')) return clean;
  if (!/^[a-z][a-z0-9+.-]*:/i.test(clean)) return clean;
  return '';
}

function hydrateRichContent(root) {
  typesetMath(root);
  renderMermaidBlocks(root);
}

function typesetMath(root) {
  if (!window.katex) return;

  root.querySelectorAll('.math-inline[data-math], .math-block[data-math]').forEach((element) => {
    const math = element.dataset.math || '';
    const displayMode = element.classList.contains('math-block');
    try {
      window.katex.render(math, element, {
        displayMode,
        throwOnError: false,
        strict: false
      });
    } catch {
      element.classList.add('rich-error');
    }
  });
}

async function loadMermaid() {
  if (!mermaidPromise) {
    mermaidPromise = import('./vendor/mermaid/mermaid.esm.min.mjs').then((module) => {
      const mermaid = module.default;
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default'
      });
      return mermaid;
    });
  }
  return mermaidPromise;
}

async function renderMermaidBlocks(root) {
  const nodes = [...root.querySelectorAll('.mermaid-block[data-mermaid]')];
  if (!nodes.length) return;

  let mermaid;
  try {
    mermaid = await loadMermaid();
  } catch {
    nodes.forEach((node) => node.classList.add('rich-error'));
    return;
  }

  for (const node of nodes) {
    const code = node.dataset.mermaid || '';
    const id = `tm-mermaid-${Date.now()}-${mermaidRenderCount++}`;
    try {
      const result = await mermaid.render(id, code);
      if (node.isConnected) {
        node.innerHTML = result.svg;
        result.bindFunctions?.(node);
      }
    } catch {
      if (node.isConnected) {
        node.classList.add('rich-error');
        node.innerHTML = `<pre><code>${escapeHtml(code)}</code></pre>`;
      }
    }
  }
}

function importImageFile(file, fallbackName = 'image.png') {
  const reader = new FileReader();
  reader.onload = () => {
    post('importImage', {
      name: file.name || fallbackName,
      dataURL: reader.result
    });
  };
  reader.onerror = () => showToast('图片读取失败');
  reader.readAsDataURL(file);
}

function insertMarkdownAtCursor(markdown) {
  if (app.classList.contains('mode-source')) {
    const start = source.selectionStart ?? source.value.length;
    const end = source.selectionEnd ?? start;
    source.setRangeText(markdown, start, end, 'end');
    blocks = parseBlocks(source.value);
    setDirty(true);
    refreshFindIfOpen();
    return;
  }

  const index = activeIndex();
  const element = activeElement();
  if (index < 0 || !element) {
    blocks.push(makeBlock(markdown));
    activeBlockId = blocks[blocks.length - 1].id;
  } else {
    syncActiveBlock();
    const caret = getCaretOffset(element);
    const raw = blocks[index].raw;
    blocks[index].raw = `${raw.slice(0, caret)}${markdown}${raw.slice(caret)}`;
  }

  source.value = getMarkdown();
  setDirty(true);
  renderLiveEditor();
  refreshFindIfOpen();
  focusBlock(activeBlockId, 'end');
}

function handleContextMenu(event) {
  const target = event.target.nodeType === Node.ELEMENT_NODE ? event.target : event.target.parentElement;
  const opened = showModeContextMenuAt(event.clientX, event.clientY, target);

  if (opened) {
    event.preventDefault();
    event.stopPropagation();
  }
}

function showModeContextMenuAt(x, y, target) {
  if (app.classList.contains('mode-live')) {
    return showLiveContextMenuAt(x, y, target);
  }
  return showGeneralContextMenuAt(x, y, target);
}

function showLiveContextMenuAt(x, y, target) {
  return showEditorContextMenuAt(x, y, target) || showGeneralContextMenuAt(x, y, target);
}

function showEditorContextMenuAt(x, y, target) {
  const blockEl = blockForContextTarget(x, y, target);

  if (!blockEl || !liveEditor.contains(blockEl) || !app.classList.contains('mode-live')) {
    return false;
  }

  syncActiveBlock();

  const blockId = blockEl.dataset.id;
  const block = blocks.find((item) => item.id === blockId);
  if (!block) return false;

  const type = blockType(block.raw);
  const cell = target?.closest('th, td, .table-cell');
  let items;
  const shouldRenderActiveBlock = activeBlockId !== blockId;

  if (type === 'table' && cell) {
    const row = tableCellRow(cell);
    const col = Number(cell.dataset.col ?? cell.cellIndex ?? 0);
    const section = cell.tagName.toLowerCase() === 'th' || cell.dataset.section === 'head' ? 'head' : 'body';
    activeBlockId = blockId;
    items = tableContextItems(blockId, section, row, col);
  } else {
    activeBlockId = blockId;
    items = blockContextItems(blockId);
  }

  if (shouldRenderActiveBlock) {
    renderLiveEditor();
  }
  showContextMenu(x, y, items);
  return true;
}

function showGeneralContextMenuAt(x, y, target) {
  if (!app.contains(target)) return false;

  const mode = currentMode();
  const selection = selectedTextForContextMenu();
  const items = generalContextItems(mode, selection);

  showContextMenu(x, y, items);
  return true;
}

function selectedTextForContextMenu() {
  if (document.activeElement === source) {
    return source.value.slice(source.selectionStart ?? 0, source.selectionEnd ?? 0);
  }
  return window.getSelection()?.toString() || '';
}

function generalContextItems(mode, selection) {
  if (mode === 'mode-source') {
    return [
      ...textEditContextItems(),
      { label: '全选', action: () => selectCurrentModeContent() },
      { separator: true },
      { label: '查找', action: () => showFind(false) },
      { label: '替换', action: () => showFind(true) },
      { separator: true },
      ...modeSwitchContextItems(mode),
      { separator: true },
      { label: '复制全文 Markdown', action: () => copyTextToClipboard(source.value, '已复制全文') },
      { label: '复制章节正文', action: () => copyChapterBody() },
      { label: '偏好设置', action: () => showSettings() }
    ];
  }

  if (mode === 'mode-preview') {
    return [
      selection
        ? { label: '复制选中内容', action: () => document.execCommand('copy') }
        : { label: '复制全文', action: () => copyTextToClipboard(preview.innerText.trim() || getMarkdown(), '已复制全文') },
      { label: '全选', action: () => selectCurrentModeContent() },
      { separator: true },
      { label: '查找', action: () => showFind(false) },
      { separator: true },
      ...modeSwitchContextItems(mode),
      { separator: true },
      { label: '复制章节正文', action: () => copyChapterBody() },
      { label: '偏好设置', action: () => showSettings() }
    ];
  }

  return [
    ...textEditContextItems(),
    { label: '全选', action: () => selectCurrentModeContent() },
    { separator: true },
    { label: '查找', action: () => showFind(false) },
    { label: '替换', action: () => showFind(true) },
    { separator: true },
    ...modeSwitchContextItems(mode),
    { separator: true },
    { label: editorPreferences.focusMode ? '关闭专注模式' : '开启专注模式', action: () => toggleFocusMode() },
    { label: editorPreferences.typewriterMode ? '关闭打字机模式' : '开启打字机模式', action: () => toggleTypewriterMode() },
    { label: '偏好设置', action: () => showSettings() }
  ];
}

function textEditContextItems() {
  return [
    { label: '剪切', action: () => document.execCommand('cut') },
    { label: '复制', action: () => document.execCommand('copy') },
    { label: '粘贴', action: () => document.execCommand('paste') }
  ];
}

function modeSwitchContextItems(current) {
  const items = [];
  if (current !== 'mode-live') {
    items.push({ label: '切换到 Live 模式', action: () => setMode('mode-live') });
  }
  if (current !== 'mode-source') {
    items.push({ label: '切换到源码模式', action: () => setMode('mode-source') });
  }
  if (current !== 'mode-preview') {
    items.push({ label: '切换到阅读模式', action: () => setMode('mode-preview') });
  }
  return items;
}

function selectCurrentModeContent() {
  if (app.classList.contains('mode-source')) {
    source.focus();
    source.select();
    updateStatusBar();
    return;
  }

  const root = app.classList.contains('mode-preview') ? preview : liveEditor;
  const range = document.createRange();
  range.selectNodeContents(root);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  updateStatusBar();
}

function blockForContextTarget(x, y, target) {
  const elementTarget = target?.nodeType === Node.ELEMENT_NODE ? target : target?.parentElement;
  const directBlock = elementTarget?.closest?.('.tm-block');
  if (directBlock) return directBlock;

  const pointTarget = document.elementFromPoint(x, y);
  const pointBlock = pointTarget?.closest?.('.tm-block');
  if (pointBlock) return pointBlock;

  return [...liveEditor.querySelectorAll('.tm-block')].find((block) => {
    const rect = block.getBoundingClientRect();
    return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
  });
}

function tableCellRow(cell) {
  if (cell.dataset.section === 'head' || cell.tagName.toLowerCase() === 'th') return 0;
  if (cell.dataset.row !== undefined) return Number(cell.dataset.row || 0);
  return cell.parentElement?.sectionRowIndex ?? 0;
}

function blockContextItems(blockId) {
  return [
    ...textEditContextItems(),
    { separator: true },
    { label: '在上方插入段落', action: () => insertBlockNear(blockId, 'before') },
    { label: '在下方插入段落', action: () => insertBlockNear(blockId, 'after') },
    { label: '插入表格', action: () => insertTableNear(blockId) },
    { separator: true },
    { label: '转为正文', action: () => convertBlock(blockId, 'paragraph') },
    { label: '转为标题', action: () => convertBlock(blockId, 'heading') },
    { label: '转为引用', action: () => convertBlock(blockId, 'quote') },
    { label: '转为无序列表', action: () => convertBlock(blockId, 'list') },
    { separator: true },
    { label: editorPreferences.focusMode ? '关闭专注模式' : '开启专注模式', action: () => toggleFocusMode() },
    { label: editorPreferences.typewriterMode ? '关闭打字机模式' : '开启打字机模式', action: () => toggleTypewriterMode() },
    { separator: true },
    { label: '查找', action: () => showFind(false) },
    { label: '替换', action: () => showFind(true) },
    { separator: true },
    { label: '复制章节正文', action: () => copyChapterBody() },
    { label: '复制块 Markdown', action: () => copyBlockMarkdown(blockId) },
    { label: '复制块副本', action: () => duplicateBlock(blockId) },
    { label: '删除块', action: () => deleteBlock(blockId) }
  ];
}

function tableContextItems(blockId, section, row, col) {
  return [
    ...textEditContextItems(),
    { separator: true },
    { label: '在上方插入行', action: () => editTable(blockId, 'insert-row-before', row, col, section) },
    { label: '在下方插入行', action: () => editTable(blockId, 'insert-row-after', row, col, section) },
    { label: '删除当前行', action: () => editTable(blockId, 'delete-row', row, col, section) },
    { separator: true },
    { label: '在左侧插入列', action: () => editTable(blockId, 'insert-col-before', row, col, section) },
    { label: '在右侧插入列', action: () => editTable(blockId, 'insert-col-after', row, col, section) },
    { label: '删除当前列', action: () => editTable(blockId, 'delete-col', row, col, section) },
    { separator: true },
    { label: '当前列左对齐', action: () => editTable(blockId, 'align-left', row, col, section) },
    { label: '当前列居中', action: () => editTable(blockId, 'align-center', row, col, section) },
    { label: '当前列右对齐', action: () => editTable(blockId, 'align-right', row, col, section) },
    { separator: true },
    { label: '查找', action: () => showFind(false) },
    { label: '替换', action: () => showFind(true) },
    { separator: true },
    { label: '复制章节正文', action: () => copyChapterBody() },
    { label: '复制表格 Markdown', action: () => copyBlockMarkdown(blockId) },
    { label: '删除表格', action: () => deleteBlock(blockId) }
  ];
}

function showContextMenu(x, y, items) {
  hideContextMenu();

  contextMenu = document.createElement('div');
  contextMenu.className = 'context-menu';
  contextMenu.setAttribute('role', 'menu');

  items.forEach((item) => {
    if (item.separator) {
      const separator = document.createElement('div');
      separator.className = 'context-separator';
      contextMenu.appendChild(separator);
      return;
    }

    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = item.label;
    button.addEventListener('click', (event) => {
      event.stopPropagation();
      hideContextMenu();
      item.action();
    });
    contextMenu.appendChild(button);
  });

  document.body.appendChild(contextMenu);
  const rect = contextMenu.getBoundingClientRect();
  const left = Math.min(x, window.innerWidth - rect.width - 8);
  const top = Math.min(y, window.innerHeight - rect.height - 8);
  contextMenu.style.left = `${Math.max(8, left)}px`;
  contextMenu.style.top = `${Math.max(8, top)}px`;
}

function hideContextMenu() {
  contextMenu?.remove();
  contextMenu = null;
}

function hideContextMenuOnPointer(event) {
  if (!contextMenu || event.button !== 0) return;
  if (contextMenu.contains(event.target)) return;
  hideContextMenu();
}

function insertBlockNear(blockId, placement) {
  const index = blocks.findIndex((block) => block.id === blockId);
  if (index < 0) return;
  const next = makeBlock('');
  blocks.splice(placement === 'before' ? index : index + 1, 0, next);
  activeBlockId = next.id;
  markStructureChanged();
  renderLiveEditor();
  focusBlock(activeBlockId, 'start');
}

function insertTableNear(blockId) {
  const index = blocks.findIndex((block) => block.id === blockId);
  if (index < 0) return;
  const table = makeBlock('| 列 1 | 列 2 |\n| --- | --- |\n|  |  |');
  blocks.splice(index + 1, 0, table);
  activeBlockId = table.id;
  pendingTableFocus = { blockId: table.id, section: 'body', row: 0, col: 0 };
  markStructureChanged();
  renderLiveEditor();
}

function duplicateBlock(blockId) {
  const index = blocks.findIndex((block) => block.id === blockId);
  if (index < 0) return;
  const copy = makeBlock(blocks[index].raw);
  blocks.splice(index + 1, 0, copy);
  activeBlockId = copy.id;
  markStructureChanged();
  renderLiveEditor();
  focusBlock(activeBlockId, 'end');
}

function deleteBlock(blockId) {
  const index = blocks.findIndex((block) => block.id === blockId);
  if (index < 0) return;

  if (blocks.length === 1) {
    blocks[0].raw = '';
    activeBlockId = blocks[0].id;
  } else {
    blocks.splice(index, 1);
    activeBlockId = blocks[Math.max(0, index - 1)].id;
  }

  markStructureChanged();
  renderLiveEditor();
  focusBlock(activeBlockId, 'end');
}

function convertBlock(blockId, target) {
  const block = blocks.find((item) => item.id === blockId);
  if (!block) return;

  const plain = blockPlainText(block.raw);
  if (target === 'heading') block.raw = `# ${plain || '标题'}`;
  if (target === 'paragraph') block.raw = plain;
  if (target === 'quote') block.raw = `> ${plain}`;
  if (target === 'list') block.raw = plain.split('\n').filter(Boolean).map((line) => `- ${line}`).join('\n') || '- ';

  activeBlockId = blockId;
  markStructureChanged();
  renderLiveEditor();
  focusBlock(activeBlockId, 'end');
}

function blockPlainText(raw) {
  const type = blockType(raw);
  if (type === 'heading') return raw.replace(/^#{1,6}\s+/, '').trim();
  if (type === 'quote') return raw.split('\n').map((line) => line.replace(/^>\s?/, '')).join('\n').trim();
  if (type === 'list') return raw.split('\n').map((line) => line.replace(/^\s*(?:[-*+]|\d+\.)\s+/, '')).join('\n').trim();
  if (type === 'code') return raw.replace(/^```[^\n]*\n?/, '').replace(/\n?```$/, '').trim();
  if (type === 'math') return mathBlockSource(raw);
  if (type === 'table') return '表格';
  return raw.trim();
}

function editTable(blockId, operation, row, col, section) {
  const block = blocks.find((item) => item.id === blockId);
  if (!block) return;

  const model = parseTable(block.raw);
  const columns = Math.max(1, model.headers.length);
  const bodyRow = section === 'head' ? 0 : Math.max(0, row);
  const safeCol = Math.max(0, Math.min(col, columns - 1));

  if (operation === 'insert-row-before') {
    model.rows.splice(bodyRow, 0, Array.from({ length: columns }, () => ''));
  }
  if (operation === 'insert-row-after') {
    model.rows.splice(bodyRow + 1, 0, Array.from({ length: columns }, () => ''));
  }
  if (operation === 'delete-row' && model.rows.length > 1) {
    model.rows.splice(bodyRow, 1);
  }
  if (operation === 'insert-col-before' || operation === 'insert-col-after') {
    const insertAt = operation === 'insert-col-before' ? safeCol : safeCol + 1;
    model.headers.splice(insertAt, 0, `列 ${insertAt + 1}`);
    model.aligns.splice(insertAt, 0, '');
    model.rows.forEach((item) => item.splice(insertAt, 0, ''));
  }
  if (operation === 'delete-col' && columns > 1) {
    model.headers.splice(safeCol, 1);
    model.aligns.splice(safeCol, 1);
    model.rows.forEach((item) => item.splice(safeCol, 1));
  }
  if (operation.startsWith('align-')) {
    model.aligns[safeCol] = operation.replace('align-', '');
  }

  block.raw = serializeTable(model);
  activeBlockId = blockId;
  pendingTableFocus = {
    blockId,
    section: operation.includes('row') || section === 'head' ? 'body' : section,
    row: Math.min(bodyRow, model.rows.length - 1),
    col: Math.min(safeCol, model.headers.length - 1)
  };
  markStructureChanged();
  renderLiveEditor();
}

function copyBlockMarkdown(blockId) {
  const block = blocks.find((item) => item.id === blockId);
  if (!block) return;
  copyTextToClipboard(block.raw, '已复制');
}

function copyChapterBody() {
  const markdown = getMarkdown();
  const body = extractChapterBody(markdown, currentCursorLine());
  if (!body.trim()) {
    showToast('没有可复制的章节正文');
    return;
  }
  copyTextToClipboard(body, '已复制章节正文');
}

async function copyTextToClipboard(text, successMessage = '已复制') {
  try {
    if (!navigator.clipboard?.writeText) throw new Error('Clipboard API unavailable');
    await navigator.clipboard.writeText(text);
    showToast(successMessage);
    return;
  } catch {
    // WKWebView 的本地文件环境偶尔不会开放 Clipboard API，保留传统复制兜底。
  }

  const helper = document.createElement('textarea');
  helper.value = text;
  helper.setAttribute('readonly', '');
  helper.style.position = 'fixed';
  helper.style.left = '-9999px';
  helper.style.top = '0';
  document.body.appendChild(helper);
  helper.select();

  const copied = document.execCommand('copy');
  helper.remove();
  showToast(copied ? successMessage : '复制失败');
}

function currentCursorLine() {
  if (currentMode() === 'mode-source') {
    return source.value.slice(0, source.selectionStart || 0).split('\n').length;
  }

  const index = activeIndex();
  if (index < 0) return 1;

  let line = 1;
  for (let i = 0; i < index; i += 1) {
    line += blocks[i].raw.split('\n').length + 1;
  }
  return line;
}

function extractChapterBody(markdown, cursorLine = 1) {
  const normalized = String(markdown || '').replace(/\r\n/g, '\n').trimEnd();
  if (!normalized.trim()) return '';

  const lines = normalized.split('\n');
  const headings = [];
  lines.forEach((line, index) => {
    const match = line.match(/^(#{1,6})\s+(.+?)\s*$/);
    if (!match) return;
    const title = stripInlineMarkers(match[2]);
    headings.push({
      index,
      level: match[1].length,
      title,
      isChapter: looksLikeChapterTitle(title)
    });
  });

  const beforeCursor = headings.filter((heading) => heading.index + 1 <= cursorLine);
  let heading = [...beforeCursor].reverse().find((item) => item.isChapter)
    || beforeCursor[beforeCursor.length - 1]
    || headings.find((item) => item.isChapter)
    || headings[0];

  if (!heading) {
    const firstTextLine = lines.findIndex((line) => line.trim());
    if (firstTextLine >= 0 && looksLikeChapterTitle(lines[firstTextLine].trim())) {
      return trimBlankLines(lines.slice(firstTextLine + 1).join('\n'));
    }
    return trimBlankLines(normalized);
  }

  const endHeading = headings.find((item) => item.index > heading.index && item.level <= heading.level);
  return trimBlankLines(lines.slice(heading.index + 1, endHeading?.index ?? lines.length).join('\n'));
}

function looksLikeChapterTitle(value) {
  const text = stripInlineMarkers(value).replace(/\s+/g, '');
  return /^(第[0-9零一二三四五六七八九十百千万两〇]+[章节回卷集部篇]|chapter[0-9]+)/i.test(text);
}

function trimBlankLines(value) {
  return String(value || '').replace(/^\s*\n+/, '').replace(/\n+\s*$/, '').trim();
}

function markStructureChanged() {
  source.value = composeMarkdown();
  setDirty(true);
  schedulePreviewRender();
  refreshFindIfOpen();
  refreshOutlineIfOpen();
}

function showOutline() {
  hideContextMenu();
  hideSettings();
  syncDocumentForOutline();
  outlineState.headings = collectDocumentHeadings();
  outlineQuery.value = '';
  outlinePanel.hidden = false;
  document.body.classList.add('outline-sidebar-open');
  refreshOutline();
  window.setTimeout(() => {
    outlineQuery.focus();
    outlineQuery.select();
  }, 0);
}

function hideOutline() {
  outlinePanel.hidden = true;
  document.body.classList.remove('outline-sidebar-open');
}

function toggleOutlineSidebar() {
  if (outlinePanel.hidden) {
    showOutline();
  } else {
    hideOutline();
  }
}

function refreshOutlineIfOpen() {
  if (outlinePanel.hidden) return;
  syncDocumentForOutline();
  outlineState.headings = collectDocumentHeadings();
  refreshOutline();
}

function syncDocumentForOutline() {
  if (currentMode() === 'mode-source') {
    return;
  }
  source.value = getMarkdown();
}

function collectDocumentHeadings() {
  if (currentMode() === 'mode-source') {
    return collectSourceHeadings(source.value);
  }

  const headings = [];
  let sourceOffset = 0;
  let line = 1;
  blocks.forEach((block) => {
    const match = block.raw.trim().match(/^(#{1,6})\s+(.+)$/);
    if (match) {
      headings.push({
        order: headings.length,
        blockId: block.id,
        sourceStart: sourceOffset,
        line,
        level: match[1].length,
        title: stripInlineMarkers(match[2])
      });
    }

    line += block.raw.split('\n').length + 1;
    sourceOffset += block.raw.length + 2;
  });
  return headings;
}

function collectSourceHeadings(markdown) {
  const headings = [];
  const lines = String(markdown || '').replace(/\r\n/g, '\n').split('\n');
  let sourceOffset = 0;

  lines.forEach((line, index) => {
    const match = line.match(/^(#{1,6})\s+(.+)$/);
    if (match) {
      headings.push({
        order: headings.length,
        blockId: '',
        sourceStart: sourceOffset,
        line: index + 1,
        level: match[1].length,
        title: stripInlineMarkers(match[2])
      });
    }
    sourceOffset += line.length + 1;
  });

  return headings;
}

function stripInlineMarkers(value) {
  return String(value || '')
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[*_`~]/g, '')
    .trim();
}

function refreshOutline() {
  const query = outlineQuery.value.trim().toLocaleLowerCase();
  outlineState.filtered = query
    ? outlineState.headings.filter((heading) => heading.title.toLocaleLowerCase().includes(query))
    : outlineState.headings;
  outlineState.index = outlineState.filtered.length ? 0 : -1;
  renderOutlineList();
}

function renderOutlineList() {
  outlineList.innerHTML = '';

  if (!outlineState.filtered.length) {
    const empty = document.createElement('div');
    empty.className = 'outline-empty';
    empty.textContent = outlineState.headings.length ? '没有匹配的标题' : '当前文档没有标题';
    outlineList.appendChild(empty);
    outlineStatus.textContent = outlineState.headings.length ? '0 个匹配' : '0 个标题';
    return;
  }

  outlineState.filtered.forEach((heading, index) => {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = `outline-item${index === outlineState.index ? ' is-selected' : ''}`;
    item.style.paddingLeft = `${8 + (heading.level - 1) * 16}px`;
    item.setAttribute('role', 'option');
    item.setAttribute('aria-selected', index === outlineState.index ? 'true' : 'false');

    const title = document.createElement('span');
    title.className = 'outline-title';
    title.textContent = heading.title || '未命名标题';

    const line = document.createElement('span');
    line.className = 'outline-line';
    line.textContent = `行 ${heading.line}`;

    item.append(title, line);
    item.addEventListener('mouseenter', () => selectOutlineIndex(index));
    item.addEventListener('click', () => jumpToOutlineHeading(index));
    outlineList.appendChild(item);
  });

  outlineStatus.textContent = outlineState.headings.length === outlineState.filtered.length
    ? `${outlineState.filtered.length} 个标题`
    : `${outlineState.filtered.length} / ${outlineState.headings.length} 个标题`;
}

function selectOutlineIndex(index) {
  if (!outlineState.filtered.length) return;
  outlineState.index = clamp(index, 0, outlineState.filtered.length - 1);
  [...outlineList.querySelectorAll('.outline-item')].forEach((item, itemIndex) => {
    item.classList.toggle('is-selected', itemIndex === outlineState.index);
    item.setAttribute('aria-selected', itemIndex === outlineState.index ? 'true' : 'false');
  });
  outlineList.querySelector('.outline-item.is-selected')?.scrollIntoView({ block: 'nearest' });
}

function moveOutlineSelection(delta) {
  if (!outlineState.filtered.length) return;
  const current = outlineState.index < 0 ? 0 : outlineState.index;
  selectOutlineIndex(current + delta);
}

function jumpToOutlineHeading(index = outlineState.index) {
  const heading = outlineState.filtered[index];
  if (!heading) return;

  if (currentMode() === 'mode-source') {
    source.focus();
    source.setSelectionRange(heading.sourceStart, heading.sourceStart);
    scrollTextareaSelection(source);
    updateStatusBar();
    return;
  }

  if (currentMode() === 'mode-preview') {
    const element = preview.querySelectorAll('h1, h2, h3, h4, h5, h6')[heading.order];
    element?.scrollIntoView({ block: 'start', inline: 'nearest' });
    return;
  }

  activeBlockId = heading.blockId;
  renderLiveEditor();
  window.setTimeout(() => {
    const element = liveEditor.querySelector(`[data-id="${heading.blockId}"]`);
    element?.scrollIntoView({ block: 'start', inline: 'nearest' });
    focusBlock(heading.blockId, 'end');
  }, 0);
}

function handleOutlineKeydown(event) {
  if (event.key === 'Escape') {
    event.preventDefault();
    hideOutline();
    return;
  }

  if (event.key === 'Enter') {
    event.preventDefault();
    jumpToOutlineHeading();
    return;
  }

  if (event.key === 'ArrowDown') {
    event.preventDefault();
    moveOutlineSelection(1);
    return;
  }

  if (event.key === 'ArrowUp') {
    event.preventDefault();
    moveOutlineSelection(-1);
  }
}

function currentMode() {
  if (app.classList.contains('mode-source')) return 'mode-source';
  if (app.classList.contains('mode-preview')) return 'mode-preview';
  return 'mode-live';
}

function showFind(replaceMode = false) {
  hideContextMenu();
  hideSettings();
  syncDocumentForSearch();

  const selectedText = selectedTextForFind();
  if (!findQuery.value && selectedText) {
    findQuery.value = selectedText;
  }

  findState.replaceMode = Boolean(replaceMode);
  setReplaceVisible(findState.replaceMode);
  findPanel.hidden = false;
  document.body.classList.add('find-visible');
  refreshFindMatches(false);

  window.setTimeout(() => {
    findQuery.focus();
    findQuery.select();
  }, 0);
}

function hideFind() {
  findPanel.hidden = true;
  document.body.classList.remove('find-visible');
  clearFindMarks(liveEditor);
  clearFindMarks(preview);
}

function selectedTextForFind() {
  if (document.activeElement === source) {
    const text = source.value.slice(source.selectionStart ?? 0, source.selectionEnd ?? 0).trim();
    if (text && !text.includes('\n') && text.length <= 120) return text;
  }

  const selectionText = window.getSelection()?.toString().trim() || '';
  if (selectionText && !selectionText.includes('\n') && selectionText.length <= 120) {
    return selectionText;
  }
  return '';
}

function setReplaceVisible(visible) {
  replaceQuery.hidden = !visible;
  replaceOneButton.hidden = !visible;
  replaceAllButton.hidden = !visible;
  findPanel.classList.toggle('is-replace', visible);
}

function syncDocumentForSearch() {
  if (currentMode() === 'mode-source') {
    blocks = parseBlocks(source.value);
    activeBlockId = blocks[0]?.id ?? null;
    return;
  }

  source.value = getMarkdown();
}

function refreshFindIfOpen(preferredIndex = null) {
  if (findPanel.hidden) return;
  refreshFindMatches(true, preferredIndex);
}

function refreshFindMatches(preserveIndex = true, preferredIndex = null) {
  const previousKey = preserveIndex ? currentFindKey() : '';
  syncDocumentForSearch();

  findState.query = findQuery.value;
  findState.replacement = replaceQuery.value;
  findState.matches = collectFindMatches();

  if (!findState.matches.length) {
    findState.index = -1;
  } else if (Number.isInteger(preferredIndex)) {
    findState.index = clamp(preferredIndex, 0, findState.matches.length - 1);
  } else if (previousKey) {
    const nextIndex = findState.matches.findIndex((match) => findMatchKey(match) === previousKey);
    findState.index = nextIndex >= 0 ? nextIndex : clamp(findState.index, 0, findState.matches.length - 1);
  } else if (findState.index < 0) {
    findState.index = 0;
  } else {
    findState.index = clamp(findState.index, 0, findState.matches.length - 1);
  }

  updateFindStatus();
  paintFindHighlights(liveEditor);
  paintFindHighlights(preview);
}

function collectFindMatches() {
  const query = findQuery.value;
  if (!query) return [];

  if (currentMode() === 'mode-source') {
    return findRanges(source.value, query).map((range) => ({
      sourceStart: range.start,
      sourceEnd: range.end,
      start: range.start,
      end: range.end,
      text: source.value.slice(range.start, range.end)
    }));
  }

  const matches = [];
  let sourceOffset = 0;
  blocks.forEach((block, blockIndex) => {
    findRanges(block.raw, query).forEach((range) => {
      matches.push({
        blockId: block.id,
        blockIndex,
        start: range.start,
        end: range.end,
        sourceStart: sourceOffset + range.start,
        sourceEnd: sourceOffset + range.end,
        text: block.raw.slice(range.start, range.end)
      });
    });
    sourceOffset += block.raw.length + 2;
  });
  return matches;
}

function findRanges(value, query) {
  const needle = String(query || '').toLocaleLowerCase();
  if (!needle) return [];

  const haystack = String(value || '');
  const lowerHaystack = haystack.toLocaleLowerCase();
  const ranges = [];
  let cursor = 0;

  while (cursor <= lowerHaystack.length) {
    const start = lowerHaystack.indexOf(needle, cursor);
    if (start < 0) break;
    ranges.push({ start, end: start + needle.length });
    cursor = start + needle.length;
  }

  return ranges;
}

function findNext(reverse = false) {
  if (findPanel.hidden) {
    showFind(false);
  }

  refreshFindMatches(true);
  if (!findState.query) {
    findQuery.focus();
    return;
  }
  if (!findState.matches.length) return;

  findState.index = reverse
    ? (findState.index <= 0 ? findState.matches.length - 1 : findState.index - 1)
    : (findState.index >= findState.matches.length - 1 ? 0 : findState.index + 1);

  updateFindStatus();
  paintFindHighlights(liveEditor);
  paintFindHighlights(preview);
  revealCurrentMatch();
}

function findPrevious() {
  findNext(true);
}

function replaceCurrent() {
  refreshFindMatches(true);
  const match = currentFindMatch();
  if (!findState.query || !match) return;

  const preferredIndex = findState.index;
  const replacement = replaceQuery.value;

  if (currentMode() === 'mode-source') {
    source.setRangeText(replacement, match.sourceStart, match.sourceEnd, 'end');
    blocks = parseBlocks(source.value);
    activeBlockId = blocks[0]?.id ?? null;
    setDirty(true);
    refreshFindMatches(false, preferredIndex);
    revealCurrentMatch();
    return;
  }

  syncActiveBlock();
  const block = blocks.find((item) => item.id === match.blockId);
  if (!block) return;

  block.raw = `${block.raw.slice(0, match.start)}${replacement}${block.raw.slice(match.end)}`;
  source.value = composeMarkdown();
  setDirty(true);
  renderCurrentMode();
  refreshFindMatches(false, preferredIndex);
  revealCurrentMatch();
}

function replaceAllMatches() {
  syncDocumentForSearch();
  const query = findQuery.value;
  if (!query) {
    findQuery.focus();
    return;
  }

  const markdown = currentMode() === 'mode-source' ? source.value : getMarkdown();
  const result = replacePlainText(markdown, query, replaceQuery.value);
  if (!result.count) {
    refreshFindMatches(false);
    return;
  }

  source.value = result.value;
  blocks = parseBlocks(result.value);
  activeBlockId = blocks[0]?.id ?? null;
  setDirty(true);
  renderCurrentMode();
  refreshFindMatches(false, 0);
  showToast(`已替换 ${result.count} 处`);
}

function replacePlainText(value, query, replacement) {
  const needle = String(query || '').toLocaleLowerCase();
  if (!needle) return { value, count: 0 };

  const input = String(value || '');
  const lowerInput = input.toLocaleLowerCase();
  let cursor = 0;
  let output = '';
  let count = 0;

  while (cursor <= input.length) {
    const start = lowerInput.indexOf(needle, cursor);
    if (start < 0) break;
    output += input.slice(cursor, start) + replacement;
    cursor = start + needle.length;
    count += 1;
  }

  return {
    value: output + input.slice(cursor),
    count
  };
}

function renderCurrentMode() {
  if (currentMode() === 'mode-source') {
    return;
  }

  if (currentMode() === 'mode-preview') {
    renderPreview();
    return;
  }

  renderLiveEditor();
  schedulePreviewRender();
}

function revealCurrentMatch() {
  const match = currentFindMatch();
  if (!match) return;

  if (currentMode() === 'mode-source') {
    source.focus();
    source.setSelectionRange(match.sourceStart, match.sourceEnd);
    scrollTextareaSelection(source);
    return;
  }

  if (currentMode() === 'mode-preview') {
    scrollCurrentFindMark(preview);
    return;
  }

  activeBlockId = match.blockId;
  renderLiveEditor();
  window.setTimeout(() => {
    const block = blocks.find((item) => item.id === match.blockId);
    const element = liveEditor.querySelector(`[data-id="${match.blockId}"]`);
    if (!block || !element) return;

    if (blockType(block.raw) === 'table') {
      focusTableMatch(match.blockId, findState.query);
      return;
    }

    element.focus();
    setTextSelection(element, match.start, match.end);
    element.scrollIntoView({ block: 'center' });
  }, 0);
}

function focusTableMatch(blockId, query) {
  const needle = String(query || '').toLocaleLowerCase();
  const cells = [...liveEditor.querySelectorAll(`[data-id="${blockId}"] .table-cell`)];
  const cell = cells.find((item) => item.textContent.toLocaleLowerCase().includes(needle)) || cells[0];
  if (!cell) return;

  const start = Math.max(0, cell.textContent.toLocaleLowerCase().indexOf(needle));
  cell.focus();
  if (start >= 0) {
    setTextSelection(cell, start, start + needle.length);
  }
  cell.scrollIntoView({ block: 'center', inline: 'nearest' });
}

function scrollTextareaSelection(textarea) {
  const textBeforeSelection = textarea.value.slice(0, textarea.selectionStart ?? 0);
  const lineIndex = textBeforeSelection.split('\n').length - 1;
  const style = window.getComputedStyle(textarea);
  const lineHeight = parseFloat(style.lineHeight) || 24;
  textarea.scrollTop = Math.max(0, lineIndex * lineHeight - textarea.clientHeight / 2);
}

function scrollCurrentFindMark(root) {
  const current = root.querySelector('.find-hit.current') || root.querySelector('.find-hit');
  current?.scrollIntoView({ block: 'center', inline: 'nearest' });
}

function updateFindStatus() {
  const total = findState.matches.length;
  findStatus.textContent = total ? `${findState.index + 1}/${total}` : '0/0';
  findPanel.classList.toggle('has-empty-query', !findState.query);
  findPanel.classList.toggle('has-no-match', Boolean(findState.query) && total === 0);
}

function currentFindMatch() {
  if (findState.index < 0 || findState.index >= findState.matches.length) return null;
  return findState.matches[findState.index];
}

function currentFindKey() {
  const match = currentFindMatch();
  return match ? findMatchKey(match) : '';
}

function findMatchKey(match) {
  if (match.blockId) return `${match.blockId}:${match.start}:${match.end}:${match.text}`;
  return `source:${match.sourceStart}:${match.sourceEnd}:${match.text}`;
}

function paintFindHighlights(root) {
  clearFindMarks(root);
  if (findPanel.hidden || !findState.query || currentMode() === 'mode-source') return;

  const textNodes = collectHighlightTextNodes(root);
  const needle = findState.query.toLocaleLowerCase();
  let ordinal = 0;

  textNodes.forEach((node) => {
    const text = node.nodeValue || '';
    const lowerText = text.toLocaleLowerCase();
    let cursor = 0;
    let found = lowerText.indexOf(needle, cursor);
    if (found < 0) return;

    const fragment = document.createDocumentFragment();
    while (found >= 0) {
      fragment.append(document.createTextNode(text.slice(cursor, found)));

      const mark = document.createElement('mark');
      mark.className = `find-hit${ordinal === findState.index ? ' current' : ''}`;
      mark.textContent = text.slice(found, found + needle.length);
      fragment.append(mark);

      cursor = found + needle.length;
      ordinal += 1;
      found = lowerText.indexOf(needle, cursor);
    }

    fragment.append(document.createTextNode(text.slice(cursor)));
    node.replaceWith(fragment);
  });
}

function collectHighlightTextNodes(root) {
  const nodes = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const parent = node.parentElement;
      if (!parent || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
      if (parent.closest('.find-hit, .is-editing, [contenteditable="true"], pre, code, .math-inline, .math-block, .katex, .mermaid-block')) {
        return NodeFilter.FILTER_REJECT;
      }
      return NodeFilter.FILTER_ACCEPT;
    }
  });

  let node = walker.nextNode();
  while (node) {
    nodes.push(node);
    node = walker.nextNode();
  }
  return nodes;
}

function clearFindMarks(root) {
  root.querySelectorAll('.find-hit').forEach((mark) => {
    const parent = mark.parentNode;
    mark.replaceWith(document.createTextNode(mark.textContent));
    parent?.normalize();
  });
}

function setTextSelection(element, start, end) {
  const range = document.createRange();
  const selection = window.getSelection();
  const rangeStart = textPositionToNodeOffset(element, start);
  const rangeEnd = textPositionToNodeOffset(element, end);

  if (!rangeStart || !rangeEnd || !selection) {
    setCaretOffset(element, end);
    return;
  }

  range.setStart(rangeStart.node, rangeStart.offset);
  range.setEnd(rangeEnd.node, rangeEnd.offset);
  selection.removeAllRanges();
  selection.addRange(range);
}

function textPositionToNodeOffset(element, offset) {
  const target = Math.max(0, Math.min(offset, element.textContent.length));
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let current = 0;
  let node = walker.nextNode();

  while (node) {
    const next = current + node.nodeValue.length;
    if (target <= next) {
      return { node, offset: target - current };
    }
    current = next;
    node = walker.nextNode();
  }

  return null;
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function showToast(message) {
  toast.textContent = message;
  toast.classList.add('show');
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => toast.classList.remove('show'), 1600);
}

function exportHTMLDocument() {
  source.value = getMarkdown();
  isRenderingExportHTML = true;
  flushPreviewRender();
  isRenderingExportHTML = false;
  const title = escapeHtml((currentName || 'TonMark').replace(/\.[^.]+$/, ''));
  const html = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title}</title>
  <style>${exportDocumentStyles()}</style>
</head>
<body>
  <article class="document">
${preview.innerHTML}
  </article>
</body>
</html>`;
  schedulePreviewRender();
  return html;
}

function exportDocumentStyles() {
  return `
:root { color-scheme: light; }
body {
  margin: 0;
  background: #fff;
  color: #1f1f1f;
  font: 16px/1.72 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
.document {
  max-width: 820px;
  margin: 0 auto;
  padding: 56px 36px 80px;
}
h1, h2, h3, h4, h5, h6 {
  line-height: 1.25;
  margin: .85em 0 .38em;
}
h1 { font-size: 2.05rem; }
h2 { font-size: 1.55rem; }
h3 { font-size: 1.25rem; }
p, ul, ol, pre, blockquote, table { margin: .72em 0; }
ul, ol { padding-left: 1.45em; }
code {
  padding: 2px 5px;
  border-radius: 4px;
  background: #f0f1f3;
  font-family: "SFMono-Regular", Menlo, Consolas, monospace;
  font-size: .92em;
}
pre {
  padding: 14px 16px;
  border-radius: 7px;
  background: #f0f1f3;
  overflow: auto;
  font-family: "SFMono-Regular", Menlo, Consolas, monospace;
}
blockquote {
  margin-left: 0;
  padding-left: 14px;
  color: #6f6f6f;
  border-left: 3px solid #dedede;
}
table {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
}
th, td {
  border: 1px solid #dedede;
  padding: 6px 8px;
  vertical-align: top;
}
th {
  background: #f4f4f4;
  font-weight: 650;
}
img {
  max-width: 100%;
  height: auto;
  border-radius: 6px;
}
hr {
  height: 1px;
  border: 0;
  background: #dedede;
}
@media print {
  .document {
    max-width: none;
    padding: 0;
  }
}`;
}

function preparePrintExport() {
  const previousMode = currentMode();
  hideContextMenu();
  hideFind();
  hideOutline();
  document.body.classList.add('is-print-export');
  setMode('mode-preview');
  return previousMode;
}

function finishPrintExport(previousMode) {
  document.body.classList.remove('is-print-export');
  if (previousMode) {
    setMode(previousMode);
  }
}

function revealLine(lineNumber) {
  const targetLine = Math.max(1, Number(lineNumber) || 1);

  if (currentMode() === 'mode-source') {
    source.focus();
    const offset = sourceOffsetForLine(source.value, targetLine);
    source.setSelectionRange(offset, offset);
    scrollTextareaSelection(source);
    updateStatusBar();
    return;
  }

  let cursorLine = 1;
  let targetBlock = blocks[0];
  for (const block of blocks) {
    const blockLineCount = block.raw.split('\n').length;
    if (targetLine >= cursorLine && targetLine < cursorLine + blockLineCount) {
      targetBlock = block;
      break;
    }
    cursorLine += blockLineCount + 1;
  }

  if (!targetBlock) return;
  if (currentMode() === 'mode-preview') {
    setMode('mode-live');
  }

  activeBlockId = targetBlock.id;
  renderLiveEditor();
  window.setTimeout(() => {
    const element = liveEditor.querySelector(`[data-id="${targetBlock.id}"]`);
    element?.scrollIntoView({ block: 'center', inline: 'nearest' });
    focusBlock(targetBlock.id, 'start');
    updateStatusBar();
  }, 0);
}

function sourceOffsetForLine(markdown, targetLine) {
  const lines = String(markdown || '').replace(/\r\n/g, '\n').split('\n');
  let offset = 0;
  for (let index = 0; index < Math.min(targetLine - 1, lines.length); index += 1) {
    offset += lines[index].length + 1;
  }
  return offset;
}

function updateStatusBar() {
  if (statusBarFrame) return;
  statusBarFrame = window.requestAnimationFrame(() => {
    statusBarFrame = 0;
    updateStatusBarNow();
  });
}

function updateStatusBarNow() {
  const stats = currentDocumentStats();
  const position = caretDocumentPosition();

  statusMode.textContent = modeLabel();
  statusCount.textContent = `${stats.characters} 字 · ${stats.words} 词`;
  statusPosition.textContent = `行 ${position.line}，列 ${position.column}`;
  statusSave.textContent = dirty ? '未保存' : '已保存';
  statusSave.classList.toggle('is-dirty', dirty);
}

function currentDocumentStats() {
  if (statusStatsRevision !== documentRevision) {
    const markdown = app.classList.contains('mode-source') ? source.value.replace(/\r\n/g, '\n') : composeMarkdown();
    statusStatsCache = documentStats(markdown);
    statusStatsRevision = documentRevision;
  }
  return statusStatsCache;
}

function modeLabel() {
  const labels = [];
  if (app.classList.contains('mode-source')) {
    labels.push('源码');
  } else if (app.classList.contains('mode-preview')) {
    labels.push('阅读');
  } else {
    labels.push('Live');
  }

  if (editorPreferences.focusMode) labels.push('专注');
  if (editorPreferences.typewriterMode) labels.push('打字机');
  return labels.join(' · ');
}

function documentStats(markdown) {
  const plain = String(markdown || '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/!\[[^\]]*\]\([^)]+\)/g, ' ')
    .replace(/\[[^\]]+\]\([^)]+\)/g, '$1')
    .replace(/[#>*_`~|[\]()-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  const characters = [...plain.replace(/\s/g, '')].length;
  const cjk = plain.match(/[\u3400-\u9fff]/g)?.length ?? 0;
  const latinWords = plain.match(/[A-Za-z0-9]+(?:[-'][A-Za-z0-9]+)*/g)?.length ?? 0;
  return {
    characters,
    words: cjk + latinWords
  };
}

function caretDocumentPosition() {
  if (app.classList.contains('mode-source')) {
    return sourceCaretPosition();
  }

  if (app.classList.contains('mode-preview')) {
    return { line: 1, column: 1 };
  }

  return liveCaretPosition();
}

function sourceCaretPosition() {
  const before = source.value.replace(/\r\n/g, '\n').slice(0, source.selectionStart ?? 0);
  const lines = before.split('\n');
  return {
    line: lines.length,
    column: [...(lines[lines.length - 1] || '')].length + 1
  };
}

function liveCaretPosition() {
  const index = activeIndex();
  if (index < 0) return { line: 1, column: 1 };

  let line = 1;
  for (let blockIndex = 0; blockIndex < index; blockIndex += 1) {
    line += blocks[blockIndex].raw.split('\n').length + 1;
  }

  const element = activeElement();
  if (!element || element.dataset.type === 'table') {
    return { line, column: 1 };
  }

  const before = blocks[index].raw.slice(0, getCaretOffset(element));
  const lines = before.split('\n');
  return {
    line: line + lines.length - 1,
    column: [...(lines[lines.length - 1] || '')].length + 1
  };
}

function setMode(nextMode) {
  hideContextMenu();
  const previousMode = [...app.classList].find((name) => name.startsWith('mode-')) || 'mode-live';

  if (previousMode === 'mode-source') {
    blocks = parseBlocks(source.value);
    activeBlockId = blocks[0]?.id ?? null;
  } else {
    source.value = getMarkdown();
  }

  app.classList.remove('mode-live', 'mode-source', 'mode-preview');
  app.classList.add(nextMode);

  if (nextMode === 'mode-live') {
    renderLiveEditor();
    window.setTimeout(() => focusBlock(activeBlockId || blocks[0]?.id, 'end'), 0);
  }

  if (nextMode === 'mode-source') {
    source.value = getMarkdown();
    window.setTimeout(() => source.focus(), 0);
  }

  if (nextMode === 'mode-preview') {
    renderPreview();
  }

  refreshFindIfOpen();
  refreshOutlineIfOpen();
  updateStatusBar();
  scheduleTypewriterScroll();
}

window.TonMark = {
  commands: {
    save() {
      post('save', { content: getMarkdown() });
    },
    saveAs() {
      post('saveAs', { content: getMarkdown() });
    },
    currentMarkdown() {
      return getMarkdown();
    },
    exportHTML() {
      return exportHTMLDocument();
    },
    preparePrintExport() {
      return preparePrintExport();
    },
    finishPrintExport(previousMode) {
      finishPrintExport(previousMode);
    },
    discardDraft() {
      clearDraft();
      setDirty(false);
    },
    togglePreview() {
      const order = ['mode-live', 'mode-source', 'mode-preview'];
      const current = order.findIndex((mode) => app.classList.contains(mode));
      setMode(order[(current + 1) % order.length]);
    },
    showContextMenuAt(x, y) {
      const target = document.elementFromPoint(x, y);
      return showEditorContextMenuAt(x, y, target);
    },
    showFind(replaceMode = false) {
      showFind(replaceMode);
    },
    showOutline() {
      showOutline();
    },
    toggleOutlineSidebar() {
      toggleOutlineSidebar();
    },
    showSettings() {
      showSettings();
    },
    setTheme(theme) {
      setEditorTheme(theme);
    },
    adjustFontSize(delta) {
      adjustEditorFontSize(delta);
    },
    adjustLineHeight(delta) {
      adjustEditorLineHeight(delta);
    },
    resetTypography() {
      resetEditorTypography();
    },
    copyChapterBody() {
      copyChapterBody();
    },
    toggleFocusMode() {
      toggleFocusMode();
    },
    toggleTypewriterMode() {
      toggleTypewriterMode();
    },
    findNext() {
      findNext(false);
    },
    findPrevious() {
      findPrevious();
    }
  },
  receive(payload) {
    if (payload.type === 'newDocument') {
      setDocument('Untitled.md', '', starter);
      return;
    }
    if (payload.type === 'fileOpened') {
      setDocument(payload.name, payload.path, payload.content, payload.basePath);
      return;
    }
    if (payload.type === 'saved') {
      setDirty(false);
      if (payload.name) currentName = payload.name;
      if (payload.path) currentPath = payload.path;
      if (payload.basePath) setBasePath(payload.basePath);
      clearDraft();
      showToast('已保存');
      return;
    }
    if (payload.type === 'imageImported') {
      insertMarkdownAtCursor(payload.markdown || '');
      showToast('图片已插入');
      return;
    }
    if (payload.type === 'revealLine') {
      window.setTimeout(() => revealLine(payload.line), 0);
      return;
    }
    if (payload.type === 'restoreSnapshot') {
      setDocument(currentName, currentPath, payload.content || '', currentBasePath, { dirty: true });
      showToast('已恢复快照，保存后写入文件');
      return;
    }
    if (payload.type === 'sidebarVisibility') {
      document.body.classList.toggle('sidebar-collapsed', Boolean(payload.hidden));
      return;
    }
    if (payload.type === 'toast') {
      showToast(payload.message);
    }
  }
};

findQuery.addEventListener('input', () => refreshFindMatches(false));
replaceQuery.addEventListener('input', () => {
  findState.replacement = replaceQuery.value;
});

findQuery.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    findNext(event.shiftKey);
  }
  if (event.key === 'Escape') {
    event.preventDefault();
    hideFind();
  }
});

replaceQuery.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    if (event.shiftKey) {
      findPrevious();
    } else {
      replaceCurrent();
    }
  }
  if (event.key === 'Escape') {
    event.preventDefault();
    hideFind();
  }
});

findPrevButton.addEventListener('click', () => findPrevious());
findNextButton.addEventListener('click', () => findNext(false));
replaceOneButton.addEventListener('click', () => replaceCurrent());
replaceAllButton.addEventListener('click', () => replaceAllMatches());
findCloseButton.addEventListener('click', () => hideFind());
outlineQuery.addEventListener('input', () => refreshOutline());
outlineQuery.addEventListener('keydown', handleOutlineKeydown);
outlineList.addEventListener('keydown', handleOutlineKeydown);
outlineCloseButton.addEventListener('click', () => hideOutline());
settingsTheme.addEventListener('change', () => updateEditorPreferences({ theme: settingsTheme.value }));
settingsFontSize.addEventListener('input', () => updateEditorPreferences({ fontSize: Number(settingsFontSize.value) }));
settingsLineHeight.addEventListener('input', () => updateEditorPreferences({ lineHeight: Number(settingsLineHeight.value) }));
settingsWidth.addEventListener('change', () => updateEditorPreferences({ width: settingsWidth.value }));
settingsFocusMode.addEventListener('change', () => updateEditorPreferences({ focusMode: settingsFocusMode.checked }));
settingsTypewriterMode.addEventListener('change', () => updateEditorPreferences({ typewriterMode: settingsTypewriterMode.checked }));
settingsCloseButton.addEventListener('click', () => hideSettings());
settingsResetButton.addEventListener('click', () => resetEditorPreferences());
restoreDraftButton.addEventListener('click', () => restoreDraft());
discardDraftButton.addEventListener('click', () => discardDraft());

window.addEventListener('pagehide', () => saveDraftNow());
window.addEventListener('beforeunload', () => saveDraftNow());

source.addEventListener('input', () => {
  setDirty(true);
  refreshFindIfOpen();
  refreshOutlineIfOpen();
});

source.addEventListener('keyup', () => updateStatusBar());
source.addEventListener('mouseup', () => updateStatusBar());
source.addEventListener('select', () => updateStatusBar());

source.addEventListener('paste', (event) => {
  const imageItems = [...(event.clipboardData?.items || [])].filter((item) => item.type.startsWith('image/'));
  if (!imageItems.length) return;
  event.preventDefault();
  imageItems.forEach((item, index) => {
    const file = item.getAsFile();
    if (file) importImageFile(file, `pasted-image-${index + 1}.png`);
  });
});

source.addEventListener('keydown', (event) => {
  if (event.metaKey && event.key.toLowerCase() === 's') {
    event.preventDefault();
    window.TonMark.commands.save();
  }
});

['dragenter', 'dragover'].forEach((eventName) => {
  document.addEventListener(eventName, (event) => {
    if ([...(event.dataTransfer?.items || [])].some((item) => item.type.startsWith('image/'))) {
      event.preventDefault();
      document.body.classList.add('is-dropping-image');
    }
  });
});

['dragleave', 'drop'].forEach((eventName) => {
  document.addEventListener(eventName, () => {
    document.body.classList.remove('is-dropping-image');
  });
});

document.addEventListener('drop', (event) => {
  const files = [...(event.dataTransfer?.files || [])].filter((file) => file.type.startsWith('image/'));
  if (!files.length) return;
  event.preventDefault();
  files.forEach((file) => importImageFile(file));
});

document.addEventListener('contextmenu', handleContextMenu, true);
document.addEventListener('mousedown', hideContextMenuOnPointer, true);
document.addEventListener('mousedown', (event) => {
  if (event.button === 0 && event.ctrlKey) {
    handleContextMenu(event);
  }
}, true);
document.addEventListener('click', (event) => {
  if (contextMenu && !contextMenu.contains(event.target)) hideContextMenu();
  if (!settingsPanel.hidden && !settingsPanel.contains(event.target)) hideSettings();
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    if (!settingsPanel.hidden) {
      event.preventDefault();
      hideSettings();
      return;
    }
    if (!outlinePanel.hidden) {
      event.preventDefault();
      hideOutline();
      return;
    }
  }

  if (event.metaKey && event.key === ',') {
    event.preventDefault();
    showSettings();
    return;
  }

  if (event.metaKey && event.key.toLowerCase() === 'f') {
    event.preventDefault();
    showFind(event.altKey);
    return;
  }

  if (event.metaKey && event.key.toLowerCase() === 'g') {
    event.preventDefault();
    findNext(event.shiftKey);
    return;
  }

  if (event.key === 'Escape') {
    if (!outlinePanel.hidden) {
      hideOutline();
      return;
    }
    if (!findPanel.hidden && findPanel.contains(document.activeElement)) {
      hideFind();
      return;
    }
    hideContextMenu();
  }
});

document.addEventListener('selectionchange', () => {
  const element = activeElement();
  if (element && element.contains(document.activeElement)) {
    syncActiveBlock();
  }
  updateStatusBar();
});

post('ready');
