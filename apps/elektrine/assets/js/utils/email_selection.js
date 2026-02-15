/**
 * Email Selection Utilities
 * Handles checkbox updates, keyboard shortcuts, and shift+click for message selection
 */

/**
 * Update message checkboxes based on selection state
 */
export function updateCheckboxes({ selected_ids, select_all }) {
  const checkboxes = document.querySelectorAll('[id^="message-checkbox-"]')
  checkboxes.forEach(checkbox => {
    const messageId = parseInt(checkbox.id.replace('message-checkbox-', ''))
    const isSelected = select_all || selected_ids.includes(messageId)

    checkbox.checked = isSelected

    const messageCard = document.getElementById(`message-${messageId}`)
    if (messageCard) {
      messageCard.classList.toggle('message-selected', isSelected)
    }
  })
}

/**
 * Handle keyboard shortcuts for message selection
 */
export function handleSelectionKeyboard(e) {
  // Only handle shortcuts when not typing in an input
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return

  // Ctrl+A or Cmd+A - Select all messages on page
  if ((e.ctrlKey || e.metaKey) && e.key === 'a') {
    e.preventDefault()
    const selectAllBtn = document.querySelector('[phx-click="select_all_messages"]')
    if (selectAllBtn) selectAllBtn.click()
  }

  // Escape - Clear selection
  if (e.key === 'Escape') {
    const clearBtn = document.querySelector('[phx-click="deselect_all_messages"]')
    if (clearBtn) clearBtn.click()
  }
}

/**
 * Handle shift+click and checkbox clicks for message selection
 */
export function handleSelectionClick(e) {
  const messageCard = e.target.closest('[phx-click="toggle_message_selection_on_shift"]')
  if (messageCard && e.shiftKey) {
    e.preventDefault()
    e.stopPropagation()
    const messageId = messageCard.getAttribute('phx-value-message_id')
    const checkbox = document.getElementById(`message-checkbox-${messageId}`)
    if (checkbox) {
      checkbox.click()
    }
  }

  // Handle individual checkbox clicks for immediate visual feedback
  if (e.target.type === 'checkbox' && e.target.id.startsWith('message-checkbox-')) {
    const messageId = e.target.id.replace('message-checkbox-', '')
    const messageCard = document.getElementById(`message-${messageId}`)
    if (messageCard) {
      setTimeout(() => {
        messageCard.classList.toggle('message-selected', e.target.checked)
      }, 50)
    }
  }
}

/**
 * Initialize email selection handlers
 */
export function initEmailSelection() {
  window.addEventListener("phx:update_checkboxes", (e) => updateCheckboxes(e.detail))
  document.addEventListener('keydown', handleSelectionKeyboard)
  document.addEventListener('click', handleSelectionClick)
}
