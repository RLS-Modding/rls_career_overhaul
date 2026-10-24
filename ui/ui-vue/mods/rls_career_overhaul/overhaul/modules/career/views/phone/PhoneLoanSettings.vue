<template>
  <div class="phone-loan-settings">
    <div class="section">
      <div class="section-title">Notifications</div>
      <div class="section-card">
        <p class="settings-hint">
          Loan alerts are managed in <strong>Settings → Notifications</strong> after the Loans app is installed.
        </p>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
.phone-loan-settings {
    background:
        radial-gradient(110% 80% at 50% -10%, rgba(99, 102, 241, 0.35) 0%, rgba(99, 102, 241, 0) 70%),
        linear-gradient(180deg, #030712 0%, #0b1227 56%, #0f172a 100%);
    padding: 12px;
    padding-top: 58px;
    color: #e2e8f0;
    height: 100%;
    overflow-y: auto;
    overflow-x: hidden;
    box-sizing: border-box;
}

.section {
    margin-bottom: 14px;
}

.section-title {
    font-size: 0.75rem;
    letter-spacing: 0.11em;
    text-transform: uppercase;
    font-weight: 700;
    margin: 2px 3px 8px;
    color: #93c5fd;
    opacity: 0.95;
}

.section-card {
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.8) 0%, rgba(15, 23, 42, 0.8) 100%);
    border: 1px solid rgba(148, 163, 184, 0.3);
    border-radius: 14px;
    padding: 12px;
    box-shadow: 0 10px 30px rgba(2, 6, 23, 0.35);
}

.settings-hint {
    margin: 0;
    font-size: 0.92em;
    line-height: 1.45;
    color: rgba(226, 232, 240, 0.9);
}
</style>
