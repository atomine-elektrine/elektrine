// Cycles through taglines on the homepage
export function initTaglineCycler() {
  const taglineElements = document.querySelectorAll('[data-taglines]')

  taglineElements.forEach(element => {
    const taglines = JSON.parse(element.getAttribute('data-taglines'))
    let currentIndex = 0

    // Cycle through taglines every 4 seconds
    setInterval(() => {
      currentIndex = (currentIndex + 1) % taglines.length

      // Fade out
      element.style.transition = 'opacity 0.3s ease-out'
      element.style.opacity = '0'

      // Change text and fade in
      setTimeout(() => {
        element.textContent = taglines[currentIndex]
        element.style.opacity = '1'
      }, 300)
    }, 4000)
  })
}
