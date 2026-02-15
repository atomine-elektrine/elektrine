// Email raw view functions
export function initEmailRaw() {
  // Handle download original email
  document.addEventListener('click', (e) => {
    if (e.target.closest('[data-action="download-original"]')) {
      e.preventDefault();
      const rawContent = document.getElementById('raw-email');
      if (rawContent) {
        const blob = new Blob([rawContent.textContent], { type: 'message/rfc822' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = 'email.eml';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
      }
    }

    // Handle copy raw email
    if (e.target.closest('[data-action="copy-raw-email"]')) {
      e.preventDefault();
      const rawContent = document.getElementById('raw-email');
      if (rawContent) {
        navigator.clipboard.writeText(rawContent.textContent).then(() => {
          const btn = e.target.closest('button');
          const originalText = btn.innerHTML;
          btn.innerHTML = '<span class="text-success">Copied!</span>';
          setTimeout(() => {
            btn.innerHTML = originalText;
          }, 2000);
        });
      }
    }

    // Handle print
    if (e.target.closest('[data-action="print"]')) {
      e.preventDefault();
      window.print();
    }
  });
}