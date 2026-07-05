/**
 * Central export for all LiveView hooks
 * Organized by feature area for maintainability.
 */

// Chat hooks
import {
  AutoExpandTextarea,
  SimpleChatInput,
  MessageList,
  ChatKeyboardShortcuts,
} from "./chat_hooks";
import { ChatE2EE } from "./chat_e2ee_hook";
import {
  ContextMenu,
  MessageContextMenu,
  CopyChatMessage,
} from "./chat_context_menu_hooks";
import { VoiceRecorder } from "./chat_voice_recorder_hook";

// Email hooks
import {
  KeyboardShortcuts,
  EmailShowKeyboardShortcuts,
} from "./email_hooks";
import { EmailComposeKeyboardShortcuts } from "./email_compose_shortcuts_hook";
import { EmailIframeResize } from "./email_iframe_resize_hook";

// Markdown hooks
import { ReplyMarkdownEditor } from "./markdown_hooks";

// Notification hooks
import {
  NotificationHandler,
  NotificationDropdown,
} from "./notification_hooks";
import { NotificationVisibility } from "./notification_visibility";
import { WebPushManager } from "./web_push_hook";

// UI hooks
import {
  PreserveFocus,
  PreserveSearchFocus,
  FlashAutoDismiss,
  TimelineReply,
  ScrollToTop,
  RemoteProfileStickyFollow,
  ImageFallback,
} from "./ui_hooks";
import { FileExplorer } from "./file_explorer_hook";
import { PaigeSearch } from "./paige_search_hook";
import {
  CopyEmail,
  CopyToClipboard,
  CopyButton,
} from "./clipboard_hooks";

// Call hooks
import {
  CallInitiator,
  CallReceiver,
  CallControls,
  VideoDisplay,
  CallTimer,
} from "./call_hooks";
import { VoiceChannel } from "./voice_channel_hook";

// Profile hooks
import {
  TypewriterHook,
  TabTitleTypewriter,
  VideoBackground,
  StatusSelector,
} from "./profile_hooks";
import { ProofGraph } from "./proof_graph_hook";
import { UPlotChart } from "./analytics_hooks";

// Timeline/Feed hooks
import {
  PostClick,
  InfiniteScroll,
} from "./timeline_hooks";
import { UserHoverCard, ImageModal } from "./timeline_media_hooks";
import {
  PreserveStreamAnchor,
  PreserveQueuedPostsButtonScroll,
} from "./timeline_preservation_hooks";
import { SessionContinuity } from "./timeline_session_continuity";
import { AnimatedCount, RemoteFollowButton } from "./timeline_status_hooks";

// Form/Utility hooks
import {
  FormSubmit,
  TagInputHook,
  SuggestionDropdown,
  VPNDownload,
  AtominePow,
} from "./form_hooks";

// Password manager hooks
import { Nerve } from "./nerve_hooks";

// Account-password encrypted data vault
import { VaultManager } from "./vault_hooks";
import { KairoVault } from "./kairo_hooks";
import { KairoGraph } from "./kairo_graph_hook";

// Mailbox private storage hooks
import {
  MailboxPrivateStorage,
} from "./mailbox_private_storage_hooks";
import { PrivateMailboxCompose } from "./mailbox_private_compose_hook";
import { PrivateMailboxMessages } from "./mailbox_private_messages_hook";

// Passkey hooks
import { PasskeyRegister, PasskeyAuth } from "./passkey_hooks";

// Presence hooks
import { ActivityTracker } from "./presence_hooks";

// Static site and profile-builder hooks
import { DragDrop, CodeEditor } from "./static_site_hooks";
import { ProfileLinkReorder } from "./profile_link_reorder_hook";

// Export all hooks as a single object
export const Hooks = {
  // Chat
  AutoExpandTextarea,
  SimpleChatInput,
  MessageList,
  ContextMenu,
  MessageContextMenu,
  ChatKeyboardShortcuts,
  CopyChatMessage,
  VoiceRecorder,
  ChatE2EE,

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
  WebPushManager,

  // UI
  CopyEmail,
  PreserveFocus,
  PreserveSearchFocus,
  FlashAutoDismiss,
  CopyToClipboard,
  FileExplorer,
  PaigeSearch,
  CopyButton,
  TimelineReply,
  ScrollToTop,
  RemoteProfileStickyFollow,
  ImageFallback,

  // Calls
  CallInitiator,
  CallReceiver,
  CallControls,
  VideoDisplay,
  CallTimer,
  VoiceChannel,

  // Profile
  TypewriterHook,
  TabTitleTypewriter,
  VideoBackground,
  StatusSelector,
  ProofGraph,
  UPlotChart,

  // Timeline/Feed
  PostClick,
  AnimatedCount,
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
  AtominePow,
  Nerve,
  VaultManager,
  KairoVault,
  KairoGraph,
  MailboxPrivateStorage,
  PrivateMailboxCompose,
  PrivateMailboxMessages,

  // Static Site
  DragDrop,
  CodeEditor,
  ProfileLinkReorder,

  // Presence
  ActivityTracker,

  // Passkey
  PasskeyRegister,
  PasskeyAuth,

  // (intentionally no product-specific hooks here)
};
