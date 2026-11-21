import { Controller } from "@hotwired/stimulus"

// Keyboard shortcuts (1-4 rate, space/enter reveal) and Anki-like audio
// autoplay on card render. Autoplay is best-effort: browsers may block it.
export default class extends Controller {
  connect() {
    this.onKeydown = this.onKeydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)

    this.element.querySelectorAll("audio[data-autoplay]").forEach((audio) => {
      audio.play().catch(() => {}) // ignore autoplay policy rejections
    })
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  onKeydown(event) {
    if (event.target.tagName === "INPUT" || event.target.tagName === "TEXTAREA") return

    const rating = event.key.match(/^[1-4]$/)
    if (rating) {
      const button = this.element.querySelector(`button[name="rating"][value="${rating[0]}"]`)
      if (button) { event.preventDefault(); button.click() }
      return
    }

    if (event.key === " " || event.key === "Enter") {
      const button = this.element.querySelector("input[type=submit], button[data-study-target=showAnswer]")
      if (button && button.name !== "rating") { event.preventDefault(); button.click() }
    }
  }
}
