export function waitingForMemberKeysMessage(memberIds, devices) {
  const deviceUserIds = new Set(
    devices
      .map(device => Number(device.user_id))
      .filter(id => Number.isInteger(id) && id > 0)
  )
  const missingCount = memberIds.filter(id => !deviceUserIds.has(id)).length

  if (missingCount <= 1) {
    return 'Waiting for one active member to register encryption keys. They need to open this chat once.'
  }

  return `Waiting for ${missingCount} active members to register encryption keys. They need to open this chat once.`
}

export function chatE2EEUnavailableLabel(status, setupRequired) {
  if (setupRequired) {
    return 'Setting up this browser'
  }

  switch (status) {
    case 'registering_device':
      return 'Registering this browser'
    case 'waiting_for_remote_keys':
      return 'Waiting for remote keys'
    case 'waiting_for_member_keys':
      return 'Waiting for member keys'
    case 'too_many_devices':
      return 'Too many devices'
    case 'not_applicable':
      return 'Encrypted chat not supported here'
    default:
      return 'Encrypted chat not ready'
  }
}

export function chatE2EEUnavailableTitle(status, setupRequired) {
  if (setupRequired) {
    return 'This browser is still registering its own encryption keys. Encrypted sending will unlock automatically.'
  }

  switch (status) {
    case 'registering_device':
      return 'This browser is registering an encryption device. Try again in a moment.'
    case 'waiting_for_remote_keys':
      return 'The remote participant has not advertised compatible chat encryption keys yet.'
    case 'waiting_for_member_keys':
      return 'Every active member needs at least one registered chat encryption device.'
    case 'too_many_devices':
      return 'This conversation has too many devices for the simple E2EE mode.'
    case 'not_applicable':
      return 'Optional client-side E2EE is currently supported for DMs and groups.'
    default:
      return 'Encrypted chat is not ready for this conversation yet.'
  }
}

export function encryptedSubmitBlockedMessage(content, hasUploads) {
  if (!content) {
    return 'Type a message before sending encrypted chat.'
  }

  if (hasUploads) {
    return 'Encrypted chat only supports plain text right now. Remove attachments or turn encrypted chat off.'
  }

  return 'Encrypted chat only supports plain text right now. Turn it off to use commands.'
}

export function encryptedSendFailureMessage(error) {
  switch (error) {
    case 'missing_key_packages':
      return 'Encrypted chat keys were not ready. Wait for the chat to finish key setup, then try again.'
    case 'invalid_key_recipient':
      return 'Encrypted chat keys changed while sending. Wait for the chat to resync, then try again.'
    case 'invalid_key_package':
    case 'invalid_encrypted_payload':
      return 'This encrypted message could not be sent because its encrypted payload was invalid.'
    case 'no_conversation':
      return 'Select a chat before sending an encrypted message.'
    case 'blocked':
      return 'This message was not sent because one of you has blocked the other.'
    case 'privacy_restricted':
      return 'This message was not sent because this user is not accepting direct messages.'
    default:
      return 'Encrypted message could not be sent. Make sure everyone has opened this chat so their keys can register, then try again.'
  }
}

export function conversationKeyPreparationMessage(deviceCount) {
  return `Preparing encryption keys for ${deviceCount} device${deviceCount === 1 ? '' : 's'}...`
}
