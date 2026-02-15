// Live server time clock for footer
export function initLiveClock() {
  const clockElements = document.querySelectorAll('[data-live-clock]');
  
  if (clockElements.length === 0) return;

  function updateClocks() {
    const now = new Date();
    const utcTime = now.toISOString().slice(11, 19) + ' UTC';
    
    clockElements.forEach(element => {
      element.textContent = element.textContent.replace(/\d{2}:\d{2}:\d{2} UTC/, utcTime);
    });
  }

  // Update every second
  setInterval(updateClocks, 1000);
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
  initLiveClock();
});

// Also initialize when navigating via LiveView
document.addEventListener('phx:page-loading-stop', () => {
  setTimeout(initLiveClock, 100);
});