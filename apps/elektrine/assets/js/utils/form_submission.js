export function submitFormPreservingEvents(form, submitter = null) {
  if (!form) return

  if (typeof form.requestSubmit === 'function') {
    if (submitter instanceof HTMLElement) {
      form.requestSubmit(submitter)
    } else {
      form.requestSubmit()
    }
    return
  }

  const transientSubmitter = document.createElement('button')
  transientSubmitter.type = 'submit'
  transientSubmitter.hidden = true
  form.appendChild(transientSubmitter)
  transientSubmitter.click()
  transientSubmitter.remove()
}
