/**
 * Central export for all LiveView hooks
 * Organized by feature area for maintainability.
 */

// Legacy tag input (from parent directory)
import { TagInput } from "../tag_input";

// Chat hooks
import {
  AutoExpandTextarea,
  SimpleChatInput,
  MessageList,
  ContextMenu,
  MessageContextMenu,
  CopyChatMessage,
  VoiceRecorder,
} from "./chat_hooks";

// Email hooks
import {
  KeyboardShortcuts,
  EmailIframeResize,
  EmailShowKeyboardShortcuts,
  EmailComposeKeyboardShortcuts,
} from "./email_hooks";

// Markdown hooks
import { ReplyMarkdownEditor } from "./markdown_hooks";

// Notification hooks
import {
  NotificationHandler,
  NotificationDropdown,
} from "./notification_hooks";
import { NotificationVisibility } from "./notification_visibility";

// UI hooks
import {
  CopyEmail,
  PreserveFocus,
  FlashAutoDismiss,
  CopyToClipboard,
  FileExplorer,
  CopyButton,
  TimelineReply,
  IframeAutoResize,
  ScrollToTop,
  ImageFallback,
} from "./ui_hooks";

// Call hooks
import {
  CallInitiator,
  CallReceiver,
  CallControls,
  VideoDisplay,
  CallTimer,
} from "./call_hooks";

// Profile hooks
import {
  TypewriterHook,
  TabTitleTypewriter,
  VideoBackground,
  StatusSelector,
} from "./profile_hooks";
import { ReputationGraph } from "./reputation_graph_hook";

// Timeline/Feed hooks
import {
  PostClick,
  RemoteFollowButton,
  InfiniteScroll,
  PreserveStreamAnchor,
  PreserveQueuedPostsButtonScroll,
  UserHoverCard,
  ImageModal,
  SessionContinuity,
} from "./timeline_hooks";

// Form/Utility hooks
import {
  FormSubmit,
  TagInputHook,
  SuggestionDropdown,
  VPNDownload,
  Turnstile,
} from "./form_hooks";

// Password manager hooks
import { PasswordVault } from "./password_manager_hooks";

// Mailbox private storage hooks
import {
  MailboxPrivateStorage,
  PrivateMailboxCompose,
  PrivateMailboxMessages,
} from "./mailbox_private_storage_hooks";

// Passkey hooks
import { PasskeyRegister, PasskeyAuth } from "./passkey_hooks";

// Presence hooks
import { ActivityTracker, DeviceDetector } from "./presence_hooks";

// Static site hooks
import { DragDrop, CodeEditor } from "./static_site_hooks";

// Export all hooks as a single object
export const Hooks = {
  // Legacy
  TagInput,

  // Chat
  AutoExpandTextarea,
  SimpleChatInput,
  MessageList,
  ContextMenu,
  MessageContextMenu,
  CopyChatMessage,
  VoiceRecorder,

  // Email
  KeyboardShortcuts,
  EmailIframeResize,
  EmailShowKeyboardShortcuts,
  EmailComposeKeyboardShortcuts,

  // Markdown
  ReplyMarkdownEditor,

  // Notifications
  NotificationHandler,
  NotificationDropdown,
  NotificationVisibility,

  // UI
  CopyEmail,
  PreserveFocus,
  FlashAutoDismiss,
  CopyToClipboard,
  FileExplorer,
  CopyButton,
  TimelineReply,
  IframeAutoResize,
  ScrollToTop,
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
  ReputationGraph,

  // Timeline/Feed
  PostClick,
  RemoteFollowButton,
  InfiniteScroll,
  PreserveStreamAnchor,
  PreserveQueuedPostsButtonScroll,
  UserHoverCard,
  ImageModal,
  SessionContinuity,

  // Form/Utility
  FormSubmit,
  TagInputHook,
  SuggestionDropdown,
  VPNDownload,
  Turnstile,
  PasswordVault,
  MailboxPrivateStorage,
  PrivateMailboxCompose,
  PrivateMailboxMessages,

  // Static Site
  DragDrop,
  CodeEditor,

  // Presence
  ActivityTracker,
  DeviceDetector,

  // Passkey
  PasskeyRegister,
  PasskeyAuth,

  // (intentionally no product-specific hooks here)
};
