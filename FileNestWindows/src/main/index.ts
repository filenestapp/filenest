import { app, BrowserWindow, Menu, Tray, globalShortcut, nativeImage, net, protocol, screen, shell, type MenuItemConstructorOptions } from 'electron'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { existsSync } from 'node:fs'
import { mkdir, stat, writeFile } from 'node:fs/promises'
import { AppController } from './app-controller'
import { registerIpc } from './ipc'

protocol.registerSchemesAsPrivileged([{ scheme: 'filenest-file', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }])

if (process.env.FILENEST_QA_CAPTURE) app.setPath('userData', join(process.cwd(), '.qa-data'))
const hasSingleInstanceLock = app.requestSingleInstanceLock()
if (!hasSingleInstanceLock) app.quit()

let mainWindow: BrowserWindow | null = null
let quickSearchWindow: BrowserWindow | null = null
let registeredQuickSearchShortcut: string | null = null
let tray: Tray | null = null
let trayMenuTimer: ReturnType<typeof setTimeout> | null = null
let quitting = false
let shutdownStarted = false
const controller = new AppController()

function resourcePath(name: string): string {
  return app.isPackaged ? join(process.resourcesPath, name) : join(process.cwd(), 'resources', name)
}

function createWindow(): BrowserWindow {
  const icon = resourcePath('app-icon.png')
  const window = new BrowserWindow({
    width: 1536,
    height: 1024,
    minWidth: 1080,
    minHeight: 700,
    show: false,
    title: 'FileNest',
    icon: existsSync(icon) ? icon : undefined,
    backgroundColor: '#F7F8FA',
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true
    }
  })
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) void shell.openExternal(url)
    return { action: 'deny' }
  })
  if (!app.isPackaged) {
    window.webContents.on('console-message', (_event, level, message) => console.log(`[renderer:${level}] ${message}`))
    window.webContents.on('did-fail-load', (_event, code, description) => console.error(`Renderer load failed ${code}: ${description}`))
  }
  window.webContents.on('will-navigate', (event, url) => {
    const current = window.webContents.getURL()
    if (url !== current) event.preventDefault()
  })
  window.on('ready-to-show', () => window.show())
  window.on('close', (event) => {
    if (!quitting && process.platform === 'win32') {
      event.preventDefault()
      window.hide()
    }
  })
  if (process.env.ELECTRON_RENDERER_URL) void window.loadURL(process.env.ELECTRON_RENDERER_URL)
  else void window.loadFile(join(__dirname, '../renderer/index.html'))
  if (process.env.FILENEST_QA_CAPTURE) {
    window.webContents.once('did-finish-load', () => {
      setTimeout(async () => {
        await window.webContents.executeJavaScript("document.querySelector('.matched-file')?.click()")
        await new Promise((resolve) => setTimeout(resolve, 400))
        const layout = await window.webContents.executeJavaScript("JSON.stringify(['.chat-page','.chat-scroll','.composer-wrap'].map(selector => { const element = document.querySelector(selector); const rect = element?.getBoundingClientRect(); return { selector, display: element ? getComputedStyle(element).display : null, rect: rect ? { x: rect.x, y: rect.y, width: rect.width, height: rect.height, bottom: rect.bottom } : null }; }))")
        console.log(`[qa-layout] ${layout}`)
        const image = await window.webContents.capturePage()
        const output = process.env.FILENEST_QA_CAPTURE!
        await mkdir(join(output, '..'), { recursive: true })
        await writeFile(output, image.toPNG())
        quitting = true
        app.quit()
      }, 1_000)
    })
  }
  return window
}

function showMainWindow(): void {
  if (!mainWindow || mainWindow.isDestroyed()) mainWindow = createWindow()
  if (mainWindow.isMinimized()) mainWindow.restore()
  mainWindow.show()
  mainWindow.focus()
}

function createQuickSearchWindow(): BrowserWindow {
  const window = new BrowserWindow({
    width: 620,
    height: 138,
    show: false,
    frame: false,
    resizable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    transparent: true,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true
    }
  })
  window.on('blur', () => window.hide())
  if (process.env.ELECTRON_RENDERER_URL) void window.loadURL(`${process.env.ELECTRON_RENDERER_URL}#quick-search`)
  else void window.loadFile(join(__dirname, '../renderer/index.html'), { hash: 'quick-search' })
  return window
}

function toggleQuickSearch(): void {
  if (!quickSearchWindow || quickSearchWindow.isDestroyed()) quickSearchWindow = createQuickSearchWindow()
  if (quickSearchWindow.isVisible()) {
    quickSearchWindow.hide()
    return
  }
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint())
  const bounds = quickSearchWindow.getBounds()
  quickSearchWindow.setPosition(
    Math.round(display.workArea.x + (display.workArea.width - bounds.width) / 2),
    Math.round(display.workArea.y + (display.workArea.height - bounds.height) / 2)
  )
  quickSearchWindow.show()
  quickSearchWindow.focus()
  quickSearchWindow.webContents.send('quick-search:focus')
}

function registerQuickSearchShortcut(shortcut: string): string | null {
  if (registeredQuickSearchShortcut) globalShortcut.unregister(registeredQuickSearchShortcut)
  registeredQuickSearchShortcut = null
  try {
    if (!globalShortcut.register(shortcut, toggleQuickSearch)) return 'The shortcut could not be registered. Choose a different combination.'
    registeredQuickSearchShortcut = shortcut
    return null
  } catch {
    return 'The shortcut could not be registered. Choose a different combination.'
  }
}

function createTray(): void {
  const path = resourcePath('tray-icon.png')
  const fallback = resourcePath('app-icon.png')
  const image = nativeImage.createFromPath(existsSync(path) ? path : fallback).resize({ width: 20, height: 20 })
  tray = new Tray(image)
  tray.setToolTip('FileNest')
  void rebuildTrayMenu()
  controller.onChanged = () => {
    if (trayMenuTimer) clearTimeout(trayMenuTimer)
    trayMenuTimer = setTimeout(() => void rebuildTrayMenu(), 180)
  }
  tray.on('double-click', showMainWindow)
}

async function rebuildTrayMenu(): Promise<void> {
  if (!tray || tray.isDestroyed()) return
  const snapshot = await controller.snapshot()
  const recent = snapshot.files.filter((file) => file.organizedAt).slice(0, 4)
  const template: MenuItemConstructorOptions[] = [
    { label: 'Open FileNest', click: showMainWindow },
    { label: 'Open Quick Search', click: toggleQuickSearch },
    { type: 'separator' },
    { label: 'Start Watching', enabled: !snapshot.watching, click: () => void controller.startWatching() },
    { label: 'Pause Watching', enabled: snapshot.watching, click: () => void controller.stopWatching() },
    snapshot.indexingPaused
      ? { label: 'Resume Indexing', click: () => controller.resumeIndexing() }
      : { label: 'Pause Indexing', enabled: snapshot.indexing, click: () => controller.pauseIndexing() },
    { label: 'Organize Now', click: () => void controller.organizeNow() },
    ...(recent.length ? [
      { type: 'separator' as const },
      { label: 'Recently Organized', enabled: false },
      ...recent.map((file) => ({ label: `  ${file.name}`, click: () => void controller.openFile(file.path) }))
    ] : []),
    { type: 'separator' },
    { label: 'Quit', click: () => { quitting = true; app.quit() } }
  ]
  tray.setContextMenu(Menu.buildFromTemplate(template))
}

if (hasSingleInstanceLock) app.whenReady().then(async () => {
  await controller.initialize()
  controller.onQuickSearchRequested = showMainWindow
  controller.onQuickSearchShortcutChanged = registerQuickSearchShortcut
  if (process.env.FILENEST_QA_CAPTURE) await seedQaFixture()
  protocol.handle('filenest-file', (request) => {
    try {
      const url = new URL(request.url)
      const encoded = url.pathname.replace(/^\//, '')
      const path = Buffer.from(encoded, 'base64url').toString('utf8')
      if (!controller.isPreviewPathAllowed(path)) return new Response('Forbidden', { status: 403 })
      return net.fetch(pathToFileURL(path).toString(), { headers: request.headers })
    } catch {
      return new Response('Bad request', { status: 400 })
    }
  })
  registerIpc(controller)
  controller.setQuickSearchShortcutError(registerQuickSearchShortcut(controller.database.getSettings().quickSearchShortcut))
  mainWindow = createWindow()
  createTray()
  app.on('activate', showMainWindow)
  app.on('second-instance', showMainWindow)
})

async function seedQaFixture(): Promise<void> {
  await controller.updateSettings({ onboardingCompleted: true, appearance: 'light', appLanguage: 'zh-Hans', llmChoice: 'none' })
  if (controller.database.listFiles().length) return
  const path = join(process.cwd(), 'design', 'windows-approved-ui.png')
  const info = await stat(path)
  const file = await controller.database.upsertFile({ path, name: 'mailchimp-receipt-MC21579651.pdf', ext: 'pdf', size: info.size, mtime: info.mtime.toISOString(), category: 'documents', sourceDir: join(process.cwd(), 'design'), indexedAt: new Date().toISOString(), contentHash: 'qa-fixture', title: 'Mailchimp Receipt MC21579651', contentText: 'The Rocket Science Group, LLC issued a service receipt to JING WANG KINTO Share.', discoveredAt: new Date().toISOString(), organizedAt: new Date().toISOString(), note: null, organizationSubfolder: 'Documents/Receipts', isDirectory: false, indexSignature: 'qa-fixture' })
  const session = await controller.database.createChat(path)
  await controller.database.updateChat(session.id, { title: 'What is this file and what does it contain?' })
  await controller.database.addMessage(session.id, 'user', 'What is this file and what does it contain?')
  await controller.database.addMessage(session.id, 'assistant', 'According to the document, this transaction is a payment between the following companies:\n\n- **Recipient (From / Issued by)**: The Rocket Science Group, LLC (Mailchimp)\n- **Payer (Issued to / Bill To)**: JING WANG KINTO Share\n- **Transaction summary**: This is a service fee charged by Mailchimp to the customer company.', [file.id])
  controller.selectChat(session.id)
}

app.on('before-quit', (event) => {
  quitting = true
  if (shutdownStarted || !hasSingleInstanceLock) return
  event.preventDefault()
  shutdownStarted = true
  void controller.shutdown().finally(() => app.quit())
})
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin' && !tray) app.quit()
})
