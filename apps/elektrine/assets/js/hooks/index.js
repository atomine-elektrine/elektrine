/**
 * Central export for all LiveView hooks
 * Organized by feature area for maintainability.
 */

// Legacy tag input (from parent directory)
import { TagInput } from '../tag_input'

// Chat hooks
import {
  AutoExpandTextarea,
  SimpleChatInput,
  MessageInput,
  MessagesContainer,
  MessageList,
  ContextMenu,
  MessageContextMenu,
  VoiceRecorder
} from './chat_hooks'

// Email hooks
import {
  KeyboardShortcuts,
  EmailContentLinks,
  EmailIframeResize,
  EmailShowKeyboardShortcuts,
  EmailComposeKeyboardShortcuts
} from './email_hooks'

// Markdown hooks
import { MarkdownEditor, ReplyMarkdownEditor } from './markdown_hooks'

// Notification hooks
import { NotificationHandler, NotificationDropdown } from './notification_hooks'
import { NotificationVisibility } from './notification_visibility'

// UI hooks
import {
  CopyEmail,
  PreserveFocus,
  FlashMessage,
  CopyToClipboard,
  CopyButton,
  FocusOnMount,
  TimelineReply,
  FileDownloader,
  IframeAutoResize,
  BackupCodesPrinter,
  DetailsPreserve,
  ScrollToTop,
  ScrollToBottom,
  GlassCard,
  GlassCardContainer,
  StopPropagation,
  Tilt3D,
  ImageFallback
} from './ui_hooks'

// Call hooks
import {
  CallInitiator,
  CallReceiver,
  CallControls,
  VideoDisplay,
  CallTimer
} from './call_hooks'

// Profile hooks
import {
  TypewriterHook,
  TabTitleTypewriter,
  VideoBackground,
  StatusSelector
} from './profile_hooks'

// Timeline/Feed hooks
import {
  PostClick,
  InfiniteScroll,
  UserHoverCard,
  ImageModal,
  DwellTimeTracker,
  NotInterestedButton,
  HidePostButton,
  SessionContextTracker
} from './timeline_hooks'

// Form/Utility hooks
import {
  FormSubmit,
  TagInputHook,
  SuggestionDropdown,
  TimezoneDetector,
  VPNDownload,
  Turnstile
} from './form_hooks'

// Passkey hooks
import {
  PasskeyRegister,
  PasskeyAuth,
  PasskeyConditionalUI
} from './passkey_hooks'

// Presence hooks
import {
  ActivityTracker,
  DeviceDetector,
  PresenceIndicator
} from './presence_hooks'

// Static site hooks
import {
  DragDrop,
  CodeEditor
} from './static_site_hooks'

// Export all hooks as a single object
export const Hooks = {
  // Legacy
  TagInput,

  // Chat
  AutoExpandTextarea,
  SimpleChatInput,
  MessageInput,
  MessagesContainer,
  MessageList,
  ContextMenu,
  MessageContextMenu,
  VoiceRecorder,

  // Email
  KeyboardShortcuts,
  EmailContentLinks,
  EmailIframeResize,
  EmailShowKeyboardShortcuts,
  EmailComposeKeyboardShortcuts,

  // Markdown
  MarkdownEditor,
  ReplyMarkdownEditor,

  // Notifications
  NotificationHandler,
  NotificationDropdown,
  NotificationVisibility,

  // UI
  CopyEmail,
  PreserveFocus,
  FlashMessage,
  CopyToClipboard,
  CopyButton,
  FocusOnMount,
  TimelineReply,
  FileDownloader,
  IframeAutoResize,
  BackupCodesPrinter,
  DetailsPreserve,
  ScrollToTop,
  ScrollToBottom,
  GlassCard,
  GlassCardContainer,
  StopPropagation,
  Tilt3D,
  ImageFallback,

  // Calls
  CallInitiator,
  CallReceiver,
  CallControls,
  VideoDisplay,
  CallTimer,

  // Profile
  TypewriterHook,
  TabTitleTypewriter,
  VideoBackground,
  StatusSelector,

  // Timeline/Feed
  PostClick,
  InfiniteScroll,
  UserHoverCard,
  ImageModal,
  DwellTimeTracker,
  NotInterestedButton,
  HidePostButton,
  SessionContextTracker,

  // Form/Utility
  FormSubmit,
  TagInputHook,
  SuggestionDropdown,
  TimezoneDetector,
  VPNDownload,
  Turnstile,

  // Static Site
  DragDrop,
  CodeEditor,

  // Presence
  ActivityTracker,
  DeviceDetector,
  PresenceIndicator,

  // Passkey
  PasskeyRegister,
  PasskeyAuth,
  PasskeyConditionalUI,

  // (intentionally no product-specific hooks here)
}
