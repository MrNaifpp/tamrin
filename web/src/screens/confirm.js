import { html } from '../../vendor/preact.js'
import { Sheet } from '../ui.js'
import { useDismissible } from '../motion.js'

/// The app's destructive alert, as a small sheet: a question, what it will
/// do, the red button, and the way back.
export function ConfirmSheet({ title, message, confirm, cancel = 'تراجع', onConfirm, onClose }) {
  const { closing, dismiss } = useDismissible(null)
  return html`
    <${Sheet} title=${title} onClose=${onClose} closing=${closing}>
      <div class="vstack" style="gap:14px">
        <p class="confirm-message">${message}</p>
        <button class="action action-remove" onClick=${() => dismiss(onConfirm)}>${confirm}</button>
        <button class="action action-glass" onClick=${() => dismiss(onClose)}>${cancel}</button>
      </div>
    <//>
  `
}
