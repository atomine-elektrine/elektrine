export function initBackupCodesPrinter(element) {
  if (!element || element.dataset.backupCodesPrinterInitialized === 'true') return

  const printButton = element.querySelector('[data-action="print"]')
  if (!printButton) return

  const handlePrint = () => {
    const codes = JSON.parse(element.dataset.codes || '[]')
    printBackupCodes(codes)
  }

  printButton.addEventListener('click', handlePrint)

  element._backupCodesPrinterCleanup = () => {
    printButton.removeEventListener('click', handlePrint)
  }

  element.dataset.backupCodesPrinterInitialized = 'true'
}

export function destroyBackupCodesPrinter(element) {
  if (!element) return

  if (typeof element._backupCodesPrinterCleanup === 'function') {
    element._backupCodesPrinterCleanup()
    delete element._backupCodesPrinterCleanup
  }

  delete element.dataset.backupCodesPrinterInitialized
}

export function initBackupCodesPrinters(rootCandidate = document) {
  const root =
    rootCandidate && typeof rootCandidate.querySelectorAll === 'function' ? rootCandidate : document

  root.querySelectorAll('[data-backup-codes-printer]').forEach((element) => {
    initBackupCodesPrinter(element)
  })
}

function printBackupCodes(codes) {
  const printWindow = window.open('', '_blank')

  const printContent = `
    <html>
    <head>
      <title>Elektrine Backup Codes</title>
      <style>
        body { font-family: Arial, sans-serif; padding: 20px; }
        .header { text-align: center; margin-bottom: 30px; }
        .codes-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; }
        .code { padding: 10px; border: 1px solid #ccc; text-align: center; font-family: monospace; font-size: 14px; }
        .warning { background-color: #fff3cd; border: 1px solid #ffeaa7; padding: 15px; margin-bottom: 20px; }
      </style>
    </head>
    <body>
      <div class="header">
        <h1>Elektrine Two-Factor Authentication</h1>
        <h2>Backup Codes</h2>
        <p>Generated on: ${new Date().toLocaleDateString()}</p>
      </div>

      <div class="warning">
        <strong>Important:</strong> Keep these codes safe and secure. Each code can only be used once to access your account if you lose your authenticator device.
      </div>

      <div class="codes-grid">
        ${codes.map(code => `<div class="code">${escapeHtml(String(code))}</div>`).join('')}
      </div>
    </body>
    </html>
  `

  printWindow.document.write(printContent)
  printWindow.document.close()
  printWindow.print()
}

function escapeHtml(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')
}
