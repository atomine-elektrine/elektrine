export function initIpLookup() {
  // Add event listeners to all IP lookup buttons
  document.addEventListener('click', function(e) {
    const button = e.target.closest('[data-ip-lookup]');
    if (!button) return;

    e.preventDefault();
    const ip = button.dataset.ipLookup;
    lookupIP(ip);
  });
}

async function lookupIP(ip) {
  const modal = document.getElementById('ip-lookup-modal');
  const content = document.getElementById('ip-lookup-content');

  if (!modal || !content) return;

  // Show modal with loading state
  content.innerHTML = '<div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>';
  modal.showModal();

  try {
    const response = await fetch(`/pripyat/lookup-ip/${encodeURIComponent(ip)}`);
    const result = await response.json();

    if (result.success) {
      const data = result.data;
      content.innerHTML = `
        <div class="space-y-3">
          <div class="grid grid-cols-2 gap-3">
            <div class="col-span-2">
              <div class="text-xs opacity-60">IP Address</div>
              <div class="font-mono font-semibold break-all text-sm">${data.ip}</div>
            </div>
            <div>
              <div class="text-xs opacity-60">Country</div>
              <div class="font-medium">${data.country} (${data.country_code})</div>
            </div>
            ${data.city ? `
            <div>
              <div class="text-xs opacity-60">City</div>
              <div>${data.city}${data.zip ? ', ' + data.zip : ''}</div>
            </div>
            ` : ''}
            ${data.region ? `
            <div>
              <div class="text-xs opacity-60">Region</div>
              <div>${data.region}</div>
            </div>
            ` : ''}
            ${data.timezone ? `
            <div>
              <div class="text-xs opacity-60">Timezone</div>
              <div>${data.timezone}</div>
            </div>
            ` : ''}
            ${data.latitude && data.longitude ? `
            <div>
              <div class="text-xs opacity-60">Coordinates</div>
              <div class="font-mono text-xs">${data.latitude}, ${data.longitude}</div>
            </div>
            ` : ''}
          </div>
          ${data.isp ? `
          <div class="pt-2 border-t">
            <div class="text-xs opacity-60">ISP</div>
            <div class="text-sm">${data.isp}</div>
          </div>
          ` : ''}
          ${data.org ? `
          <div>
            <div class="text-xs opacity-60">Organization</div>
            <div class="text-sm">${data.org}</div>
          </div>
          ` : ''}
          ${data.as ? `
          <div>
            <div class="text-xs opacity-60">AS Number</div>
            <div class="text-sm font-mono">${data.as}</div>
          </div>
          ` : ''}
        </div>
      `;
    } else {
      content.innerHTML = `
        <div class="alert alert-error">
          <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>
          <span>Failed to lookup IP: ${result.error || 'Unknown error'}</span>
        </div>
      `;
    }
  } catch (error) {
    content.innerHTML = `
      <div class="alert alert-error">
        <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>
        <span>Network error occurred</span>
      </div>
    `;
  }
}
