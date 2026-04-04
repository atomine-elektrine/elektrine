import { spinnerSvg } from './utils/spinner';

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
  content.innerHTML = `<div class="flex justify-center py-8">${spinnerSvg({ size: 'lg' })}</div>`;
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
              <div class="font-mono font-semibold break-all text-sm" data-ip-field="ip"></div>
            </div>
            <div>
              <div class="text-xs opacity-60">Country</div>
              <div class="font-medium" data-ip-field="country"></div>
            </div>
            <div class="hidden" data-ip-section="city">
              <div class="text-xs opacity-60">City</div>
              <div data-ip-value></div>
            </div>
            <div class="hidden" data-ip-section="region">
              <div class="text-xs opacity-60">Region</div>
              <div data-ip-value></div>
            </div>
            <div class="hidden" data-ip-section="timezone">
              <div class="text-xs opacity-60">Timezone</div>
              <div data-ip-value></div>
            </div>
            <div class="hidden" data-ip-section="coordinates">
              <div class="text-xs opacity-60">Coordinates</div>
              <div class="font-mono text-xs" data-ip-value></div>
            </div>
          </div>
          <div class="pt-2 border-t hidden" data-ip-section="isp">
            <div class="text-xs opacity-60">ISP</div>
            <div class="text-sm" data-ip-value></div>
          </div>
          <div class="hidden" data-ip-section="org">
            <div class="text-xs opacity-60">Organization</div>
            <div class="text-sm" data-ip-value></div>
          </div>
          <div class="hidden" data-ip-section="as">
            <div class="text-xs opacity-60">AS Number</div>
            <div class="text-sm font-mono" data-ip-value></div>
          </div>
        </div>
      `;
      populateLookupResult(content, data);
    } else {
      content.innerHTML = `
        <div class="alert alert-error">
          <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>
          <span id="ip-lookup-error-message"></span>
        </div>
      `;
      const errorEl = document.getElementById('ip-lookup-error-message');
      if (errorEl) errorEl.textContent = `Failed to lookup IP: ${result.error || 'Unknown error'}`;
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

function populateLookupResult(content, data) {
  setText(content, '[data-ip-field="ip"]', data.ip)
  setText(content, '[data-ip-field="country"]', `${data.country} (${data.country_code})`)
  toggleSection(content, 'city', data.city, `${data.city}${data.zip ? ', ' + data.zip : ''}`)
  toggleSection(content, 'region', data.region, data.region)
  toggleSection(content, 'timezone', data.timezone, data.timezone)
  toggleSection(content, 'coordinates', data.latitude && data.longitude, `${data.latitude}, ${data.longitude}`)
  toggleSection(content, 'isp', data.isp, data.isp)
  toggleSection(content, 'org', data.org, data.org)
  toggleSection(content, 'as', data.as, data.as)
}

function toggleSection(content, key, visible, value) {
  const section = content.querySelector(`[data-ip-section="${key}"]`)
  if (!section) return

  section.classList.toggle('hidden', !visible)
  if (visible) {
    const valueEl = section.querySelector('[data-ip-value]')
    if (valueEl) valueEl.textContent = value
  }
}

function setText(content, selector, value) {
  const el = content.querySelector(selector)
  if (el) el.textContent = value || ''
}
