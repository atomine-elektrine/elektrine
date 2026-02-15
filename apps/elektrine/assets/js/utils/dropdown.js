/**
 * Dropdown Management Utilities
 * Handles closing dropdowns on various events
 */

/**
 * Close all open dropdowns
 */
export function closeAllDropdowns() {
  document.querySelectorAll('.dropdown').forEach(dropdown => {
    dropdown.blur()
  })
  document.querySelectorAll('.dropdown [tabindex="0"]').forEach(trigger => {
    trigger.blur()
    const activeElement = trigger.querySelector(':focus')
    if (activeElement) {
      activeElement.blur()
    }
  })
}

/**
 * Handle clicks that should close dropdowns
 */
function handleDropdownClick(e) {
  if (e.target.closest("[phx-click]")) {
    setTimeout(closeAllDropdowns, 50)
  }
}

/**
 * Initialize dropdown management
 */
export function initDropdownManagement() {
  // Close dropdowns on phx-click
  document.addEventListener("click", handleDropdownClick)

  // Close dropdowns when window loses/regains focus
  window.addEventListener("blur", closeAllDropdowns)
  window.addEventListener("focus", closeAllDropdowns)
}
