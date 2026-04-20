--
-- PostgreSQL database dump
--


-- Dumped from database version 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: oban_job_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.oban_job_state AS ENUM (
    'available',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_deletion_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_deletion_requests (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    reason text,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    requested_at timestamp(0) without time zone NOT NULL,
    reviewed_at timestamp(0) without time zone,
    reviewed_by_id bigint,
    admin_notes text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: account_deletion_requests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_deletion_requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_deletion_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_deletion_requests_id_seq OWNED BY public.account_deletion_requests.id;


--
-- Name: activitypub_activities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activitypub_activities (
    id bigint NOT NULL,
    activity_id character varying(255) NOT NULL,
    activity_type character varying(255) NOT NULL,
    actor_uri character varying(255) NOT NULL,
    object_id character varying(255),
    data jsonb NOT NULL,
    local boolean DEFAULT false,
    internal_user_id bigint,
    internal_message_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    processed boolean DEFAULT false,
    processed_at timestamp(0) without time zone,
    process_error character varying(255),
    process_attempts integer DEFAULT 0
);


--
-- Name: activitypub_activities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activitypub_activities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activitypub_activities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activitypub_activities_id_seq OWNED BY public.activitypub_activities.id;


--
-- Name: activitypub_actors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activitypub_actors (
    id bigint NOT NULL,
    uri character varying(255) NOT NULL,
    username character varying(255) NOT NULL,
    domain character varying(255) NOT NULL,
    display_name character varying(255),
    summary text,
    avatar_url character varying(255),
    header_url character varying(255),
    inbox_url character varying(255) NOT NULL,
    outbox_url character varying(255),
    followers_url character varying(255),
    following_url character varying(255),
    public_key text NOT NULL,
    manually_approves_followers boolean DEFAULT false,
    actor_type character varying(255) DEFAULT 'Person'::character varying,
    last_fetched_at timestamp(0) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    published_at timestamp(0) without time zone,
    community_id bigint,
    moderators_url character varying(255),
    CONSTRAINT actor_type_must_be_valid CHECK (((actor_type)::text = ANY ((ARRAY['Person'::character varying, 'Group'::character varying, 'Organization'::character varying, 'Service'::character varying, 'Application'::character varying])::text[])))
);


--
-- Name: activitypub_actors_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activitypub_actors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activitypub_actors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activitypub_actors_id_seq OWNED BY public.activitypub_actors.id;


--
-- Name: activitypub_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activitypub_deliveries (
    id bigint NOT NULL,
    activity_id bigint NOT NULL,
    inbox_url character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying,
    attempts integer DEFAULT 0,
    last_attempt_at timestamp(0) without time zone,
    next_retry_at timestamp(0) without time zone,
    error_message text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: activitypub_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activitypub_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activitypub_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activitypub_deliveries_id_seq OWNED BY public.activitypub_deliveries.id;


--
-- Name: activitypub_instances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activitypub_instances (
    id bigint NOT NULL,
    domain character varying(255) NOT NULL,
    blocked boolean DEFAULT false,
    silenced boolean DEFAULT false,
    reason text,
    blocked_by_id bigint,
    blocked_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    media_removal boolean DEFAULT false,
    media_nsfw boolean DEFAULT false,
    federated_timeline_removal boolean DEFAULT false,
    followers_only boolean DEFAULT false,
    report_removal boolean DEFAULT false,
    avatar_removal boolean DEFAULT false,
    banner_removal boolean DEFAULT false,
    reject_deletes boolean DEFAULT false,
    policy_applied_at timestamp(0) without time zone,
    policy_applied_by_id bigint,
    notes text,
    unreachable_since timestamp(0) without time zone,
    failure_count integer DEFAULT 0,
    nodeinfo jsonb DEFAULT '{}'::jsonb,
    favicon character varying(255),
    metadata_updated_at timestamp(0) without time zone
);


--
-- Name: activitypub_instances_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activitypub_instances_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activitypub_instances_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activitypub_instances_id_seq OWNED BY public.activitypub_instances.id;


--
-- Name: activitypub_relay_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activitypub_relay_subscriptions (
    id bigint NOT NULL,
    relay_uri character varying(255) NOT NULL,
    follow_activity_id character varying(255),
    status character varying(255) DEFAULT 'pending'::character varying,
    relay_inbox character varying(255),
    relay_name character varying(255),
    relay_software character varying(255),
    accepted boolean DEFAULT false,
    error_message text,
    subscribed_by_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: activitypub_relay_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activitypub_relay_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activitypub_relay_subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activitypub_relay_subscriptions_id_seq OWNED BY public.activitypub_relay_subscriptions.id;


--
-- Name: activitypub_user_blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activitypub_user_blocks (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    blocked_uri character varying(255) NOT NULL,
    block_type character varying(255) DEFAULT 'user'::character varying,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: activitypub_user_blocks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activitypub_user_blocks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activitypub_user_blocks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activitypub_user_blocks_id_seq OWNED BY public.activitypub_user_blocks.id;


--
-- Name: announcement_dismissals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.announcement_dismissals (
    id bigint NOT NULL,
    dismissed_at timestamp(0) without time zone NOT NULL,
    user_id bigint NOT NULL,
    announcement_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: announcement_dismissals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.announcement_dismissals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: announcement_dismissals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.announcement_dismissals_id_seq OWNED BY public.announcement_dismissals.id;


--
-- Name: announcements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.announcements (
    id bigint NOT NULL,
    title character varying(255) NOT NULL,
    content text NOT NULL,
    type character varying(255) DEFAULT 'info'::character varying NOT NULL,
    starts_at timestamp(0) without time zone,
    ends_at timestamp(0) without time zone,
    active boolean DEFAULT true NOT NULL,
    created_by_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: announcements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.announcements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: announcements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.announcements_id_seq OWNED BY public.announcements.id;


--
-- Name: api_token_revocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_token_revocations (
    id bigint NOT NULL,
    token_hash character varying(255) NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    revoked_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: api_token_revocations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.api_token_revocations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: api_token_revocations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.api_token_revocations_id_seq OWNED BY public.api_token_revocations.id;


--
-- Name: api_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_tokens (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    token_hash character varying(255) NOT NULL,
    token_prefix character varying(255) NOT NULL,
    scopes character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    last_used_at timestamp(0) without time zone,
    last_used_ip character varying(255),
    expires_at timestamp(0) without time zone,
    revoked_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: api_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.api_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: api_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.api_tokens_id_seq OWNED BY public.api_tokens.id;


--
-- Name: app_passwords; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_passwords (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    token_hash character varying(255) NOT NULL,
    last_used_at timestamp(0) without time zone,
    last_used_ip character varying(255),
    expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: app_passwords_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.app_passwords_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: app_passwords_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.app_passwords_id_seq OWNED BY public.app_passwords.id;


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id bigint NOT NULL,
    admin_id bigint NOT NULL,
    target_user_id bigint,
    action character varying(255) NOT NULL,
    resource_type character varying(255) NOT NULL,
    resource_id integer,
    details jsonb,
    ip_address character varying(255),
    user_agent character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: audit_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_logs_id_seq OWNED BY public.audit_logs.id;


--
-- Name: auto_mod_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auto_mod_rules (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    rule_type character varying(255) NOT NULL,
    pattern text NOT NULL,
    action character varying(255) NOT NULL,
    enabled boolean DEFAULT true,
    created_by_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: auto_mod_rules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auto_mod_rules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auto_mod_rules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auto_mod_rules_id_seq OWNED BY public.auto_mod_rules.id;


--
-- Name: bluesky_inbound_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bluesky_inbound_events (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    event_id character varying(255) NOT NULL,
    reason character varying(255),
    related_post_uri text,
    processed_at timestamp(0) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: bluesky_inbound_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bluesky_inbound_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bluesky_inbound_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bluesky_inbound_events_id_seq OWNED BY public.bluesky_inbound_events.id;


--
-- Name: calendar_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calendar_events (
    id bigint NOT NULL,
    calendar_id bigint NOT NULL,
    uid character varying(255) NOT NULL,
    etag character varying(255),
    summary character varying(255),
    description text,
    location character varying(255),
    url character varying(255),
    dtstart timestamp(0) without time zone NOT NULL,
    dtend timestamp(0) without time zone,
    duration character varying(255),
    all_day boolean DEFAULT false,
    timezone character varying(255),
    rrule character varying(255),
    rdate timestamp(0) without time zone[] DEFAULT ARRAY[]::timestamp without time zone[],
    exdate timestamp(0) without time zone[] DEFAULT ARRAY[]::timestamp without time zone[],
    recurrence_id timestamp(0) without time zone,
    status character varying(255) DEFAULT 'CONFIRMED'::character varying,
    transparency character varying(255) DEFAULT 'OPAQUE'::character varying,
    classification character varying(255) DEFAULT 'PUBLIC'::character varying,
    priority integer DEFAULT 0,
    alarms jsonb[] DEFAULT ARRAY[]::jsonb[],
    attendees jsonb[] DEFAULT ARRAY[]::jsonb[],
    organizer jsonb,
    categories character varying(255)[] DEFAULT ARRAY[]::character varying[],
    icalendar_data text,
    sequence integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: calendar_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calendar_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calendar_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calendar_events_id_seq OWNED BY public.calendar_events.id;


--
-- Name: calendars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calendars (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    color character varying(255) DEFAULT '#3b82f6'::character varying,
    description text,
    timezone character varying(255) DEFAULT 'UTC'::character varying,
    is_default boolean DEFAULT false,
    ctag character varying(255),
    "order" integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: calendars_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calendars_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calendars_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calendars_id_seq OWNED BY public.calendars.id;


--
-- Name: calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calls (
    id bigint NOT NULL,
    caller_id bigint NOT NULL,
    callee_id bigint NOT NULL,
    conversation_id bigint,
    call_type character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    started_at timestamp(0) without time zone,
    ended_at timestamp(0) without time zone,
    duration_seconds integer,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: calls_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calls_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calls_id_seq OWNED BY public.calls.id;


--
-- Name: chat_conversation_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_conversation_members (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    user_id bigint NOT NULL,
    role character varying(255) DEFAULT 'member'::character varying,
    joined_at timestamp(0) without time zone DEFAULT now(),
    left_at timestamp(0) without time zone,
    last_read_at timestamp(0) without time zone,
    last_read_message_id bigint,
    notifications_enabled boolean DEFAULT true,
    pinned boolean DEFAULT false,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: chat_conversation_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_conversation_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_conversation_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_conversation_members_id_seq OWNED BY public.chat_conversation_members.id;


--
-- Name: chat_conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_conversations (
    id bigint NOT NULL,
    name character varying(255),
    description text,
    type character varying(255) NOT NULL,
    creator_id bigint,
    avatar_url character varying(255),
    is_public boolean DEFAULT false,
    member_count integer DEFAULT 0,
    last_message_at timestamp(0) without time zone,
    archived boolean DEFAULT false,
    hash character varying(255),
    slow_mode_seconds integer DEFAULT 0,
    approval_mode_enabled boolean DEFAULT false,
    approval_threshold_posts integer DEFAULT 3,
    channel_topic character varying(255),
    channel_position integer DEFAULT 0,
    server_id bigint,
    federated_source character varying(255),
    is_federated_mirror boolean DEFAULT false,
    remote_group_actor_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: chat_conversations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_conversations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_conversations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_conversations_id_seq OWNED BY public.chat_conversations.id;


--
-- Name: chat_message_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_message_reactions (
    id bigint NOT NULL,
    chat_message_id bigint NOT NULL,
    user_id bigint,
    remote_actor_id bigint,
    emoji character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: chat_message_reactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_message_reactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_message_reactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_message_reactions_id_seq OWNED BY public.chat_message_reactions.id;


--
-- Name: chat_message_reads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_message_reads (
    chat_message_id bigint NOT NULL,
    user_id bigint NOT NULL,
    read_at timestamp(0) without time zone NOT NULL
);


--
-- Name: chat_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_messages (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    sender_id bigint,
    content text,
    encrypted_content jsonb,
    search_index character varying(255)[] DEFAULT ARRAY[]::character varying[],
    message_type character varying(255) DEFAULT 'text'::character varying,
    media_urls character varying(255)[] DEFAULT ARRAY[]::character varying[],
    media_metadata jsonb DEFAULT '{}'::jsonb,
    reply_to_id bigint,
    edited_at timestamp(0) without time zone,
    deleted_at timestamp(0) without time zone,
    audio_duration integer,
    audio_mime_type character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    federated_source character varying(255),
    origin_domain character varying(255),
    is_federated_mirror boolean DEFAULT false NOT NULL,
    link_preview_id bigint
);


--
-- Name: chat_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_messages_id_seq OWNED BY public.chat_messages.id;


--
-- Name: chat_moderation_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_moderation_actions (
    id bigint NOT NULL,
    action_type character varying(255),
    reason character varying(255),
    duration integer,
    details jsonb,
    target_user_id bigint,
    moderator_id bigint,
    conversation_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: chat_moderation_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_moderation_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_moderation_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_moderation_actions_id_seq OWNED BY public.chat_moderation_actions.id;


--
-- Name: chat_user_hidden_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_user_hidden_messages (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    chat_message_id bigint NOT NULL,
    hidden_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: chat_user_hidden_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_user_hidden_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_user_hidden_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_user_hidden_messages_id_seq OWNED BY public.chat_user_hidden_messages.id;


--
-- Name: chat_user_timeouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_user_timeouts (
    id bigint NOT NULL,
    user_id bigint,
    conversation_id bigint,
    created_by_id bigint,
    timeout_until timestamp(0) without time zone,
    reason character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: chat_user_timeouts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_user_timeouts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_user_timeouts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_user_timeouts_id_seq OWNED BY public.chat_user_timeouts.id;


--
-- Name: community_bans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.community_bans (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    user_id bigint NOT NULL,
    banned_by_id bigint,
    reason text,
    expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    origin_domain character varying(255),
    actor_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    banned_at_remote timestamp(0) without time zone,
    updated_at_remote timestamp(0) without time zone
);


--
-- Name: community_bans_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.community_bans_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: community_bans_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.community_bans_id_seq OWNED BY public.community_bans.id;


--
-- Name: community_flairs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.community_flairs (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    text_color character varying(255) DEFAULT '#FFFFFF'::character varying,
    background_color character varying(255) DEFAULT '#4B5563'::character varying,
    community_id bigint NOT NULL,
    "position" integer DEFAULT 0,
    is_mod_only boolean DEFAULT false,
    is_enabled boolean DEFAULT true,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: community_flairs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.community_flairs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: community_flairs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.community_flairs_id_seq OWNED BY public.community_flairs.id;


--
-- Name: contact_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contact_groups (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    color character varying(255) DEFAULT '#3b82f6'::character varying,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: contact_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contact_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contact_groups_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contact_groups_id_seq OWNED BY public.contact_groups.id;


--
-- Name: contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contacts (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    email character varying(255) NOT NULL,
    phone character varying(255),
    organization character varying(255),
    notes text,
    favorite boolean DEFAULT false,
    group_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    uid character varying(255),
    etag character varying(255),
    prefix character varying(255),
    suffix character varying(255),
    nickname character varying(255),
    formatted_name character varying(255),
    first_name character varying(255),
    last_name character varying(255),
    middle_name character varying(255),
    emails jsonb[] DEFAULT ARRAY[]::jsonb[],
    phones jsonb[] DEFAULT ARRAY[]::jsonb[],
    addresses jsonb[] DEFAULT ARRAY[]::jsonb[],
    urls jsonb[] DEFAULT ARRAY[]::jsonb[],
    social_profiles jsonb[] DEFAULT ARRAY[]::jsonb[],
    birthday date,
    anniversary date,
    photo_type character varying(255),
    photo_data text,
    photo_content_type character varying(255),
    title character varying(255),
    department character varying(255),
    role character varying(255),
    categories character varying(255)[] DEFAULT ARRAY[]::character varying[],
    geo jsonb,
    vcard_data text,
    revision timestamp(0) without time zone,
    pgp_public_key text,
    pgp_key_id character varying(255),
    pgp_fingerprint character varying(255),
    pgp_key_source character varying(255),
    pgp_key_fetched_at timestamp(0) without time zone,
    pgp_encrypt_by_default boolean DEFAULT false
);


--
-- Name: contacts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contacts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contacts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contacts_id_seq OWNED BY public.contacts.id;


--
-- Name: conversation_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_members (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    user_id bigint NOT NULL,
    role character varying(255) DEFAULT 'member'::character varying,
    joined_at timestamp(0) without time zone DEFAULT now(),
    left_at timestamp(0) without time zone,
    last_read_at timestamp(0) without time zone,
    notifications_enabled boolean DEFAULT true,
    pinned boolean DEFAULT false,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    last_read_message_id bigint
);


--
-- Name: conversation_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversation_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversation_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversation_members_id_seq OWNED BY public.conversation_members.id;


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id bigint NOT NULL,
    name character varying(255),
    description text,
    type character varying(255) NOT NULL,
    creator_id bigint,
    avatar_url character varying(255),
    is_public boolean DEFAULT false,
    member_count integer DEFAULT 0,
    last_message_at timestamp(0) without time zone,
    archived boolean DEFAULT false,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    hash character varying(32),
    community_category character varying(255),
    allow_public_posts boolean DEFAULT false,
    discussion_style character varying(255) DEFAULT 'chat'::character varying,
    community_rules text,
    slow_mode_seconds integer DEFAULT 0,
    approval_mode_enabled boolean DEFAULT false,
    approval_threshold_posts integer DEFAULT 3,
    federated_source character varying(255),
    remote_group_actor_id bigint,
    is_federated_mirror boolean DEFAULT false,
    server_id bigint,
    channel_topic text,
    channel_position integer DEFAULT 0 NOT NULL
);


--
-- Name: conversations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversations_id_seq OWNED BY public.conversations.id;


--
-- Name: creator_satisfaction; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.creator_satisfaction (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    creator_id bigint,
    remote_actor_id bigint,
    followed_after_viewing boolean DEFAULT false,
    continued_engagement boolean DEFAULT false,
    immediate_leave boolean DEFAULT false,
    total_posts_viewed integer DEFAULT 0,
    total_dwell_time_ms integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: creator_satisfaction_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.creator_satisfaction_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: creator_satisfaction_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.creator_satisfaction_id_seq OWNED BY public.creator_satisfaction.id;


--
-- Name: custom_emojis; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.custom_emojis (
    id bigint NOT NULL,
    shortcode character varying(255) NOT NULL,
    image_url character varying(255) NOT NULL,
    instance_domain character varying(255),
    category character varying(255),
    visible_in_picker boolean DEFAULT true,
    disabled boolean DEFAULT false,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: custom_emojis_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.custom_emojis_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: custom_emojis_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.custom_emojis_id_seq OWNED BY public.custom_emojis.id;


--
-- Name: data_exports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.data_exports (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    export_type character varying(255) NOT NULL,
    format character varying(255) DEFAULT 'json'::character varying NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    file_path character varying(255),
    file_size bigint,
    item_count integer,
    filters jsonb DEFAULT '{}'::jsonb,
    download_token character varying(255),
    download_count integer DEFAULT 0,
    expires_at timestamp(0) without time zone,
    started_at timestamp(0) without time zone,
    completed_at timestamp(0) without time zone,
    error text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: data_exports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.data_exports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: data_exports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.data_exports_id_seq OWNED BY public.data_exports.id;


--
-- Name: developer_webhook_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.developer_webhook_deliveries (
    id bigint NOT NULL,
    webhook_id bigint NOT NULL,
    user_id bigint NOT NULL,
    event character varying(255) NOT NULL,
    event_id character varying(255) NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    response_status integer,
    error text,
    duration_ms integer,
    last_attempted_at timestamp(0) without time zone,
    delivered_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: developer_webhook_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.developer_webhook_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: developer_webhook_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.developer_webhook_deliveries_id_seq OWNED BY public.developer_webhook_deliveries.id;


--
-- Name: developer_webhooks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.developer_webhooks (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    url character varying(255) NOT NULL,
    events character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    secret character varying(255) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    last_triggered_at timestamp(0) without time zone,
    last_response_status integer,
    last_error text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: developer_webhooks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.developer_webhooks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: developer_webhooks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.developer_webhooks_id_seq OWNED BY public.developer_webhooks.id;


--
-- Name: device_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_tokens (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token character varying(255) NOT NULL,
    platform character varying(255) NOT NULL,
    app_version character varying(255),
    device_name character varying(255),
    device_model character varying(255),
    os_version character varying(255),
    bundle_id character varying(255),
    enabled boolean DEFAULT true,
    last_used_at timestamp(0) without time zone,
    failed_count integer DEFAULT 0,
    last_error character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: device_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.device_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: device_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.device_tokens_id_seq OWNED BY public.device_tokens.id;


--
-- Name: dns_query_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dns_query_stats (
    id bigint NOT NULL,
    query_date date NOT NULL,
    qname character varying(255) NOT NULL,
    qtype character varying(255) NOT NULL,
    rcode character varying(255) NOT NULL,
    transport character varying(255) NOT NULL,
    query_count integer DEFAULT 0 NOT NULL,
    zone_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: dns_query_stats_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dns_query_stats_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dns_query_stats_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dns_query_stats_id_seq OWNED BY public.dns_query_stats.id;


--
-- Name: dns_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dns_records (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    type character varying(255) NOT NULL,
    ttl integer DEFAULT 300 NOT NULL,
    content text NOT NULL,
    priority integer,
    weight integer,
    port integer,
    flags integer,
    tag character varying(255),
    zone_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    source character varying(255) DEFAULT 'user'::character varying NOT NULL,
    service character varying(255),
    managed boolean DEFAULT false NOT NULL,
    managed_key character varying(255),
    required boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    protocol integer,
    algorithm integer,
    key_tag integer,
    digest_type integer,
    usage integer,
    selector integer,
    matching_type integer
);


--
-- Name: dns_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dns_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dns_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dns_records_id_seq OWNED BY public.dns_records.id;


--
-- Name: dns_zone_service_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dns_zone_service_configs (
    id bigint NOT NULL,
    service character varying(255) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    mode character varying(255) DEFAULT 'managed'::character varying NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_applied_at timestamp(0) without time zone,
    last_error character varying(255),
    zone_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: dns_zone_service_configs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dns_zone_service_configs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dns_zone_service_configs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dns_zone_service_configs_id_seq OWNED BY public.dns_zone_service_configs.id;


--
-- Name: dns_zones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dns_zones (
    id bigint NOT NULL,
    domain character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'provisioning'::character varying NOT NULL,
    kind character varying(255) DEFAULT 'native'::character varying NOT NULL,
    serial bigint DEFAULT 1 NOT NULL,
    default_ttl integer DEFAULT 300 NOT NULL,
    verified_at timestamp(0) without time zone,
    last_checked_at timestamp(0) without time zone,
    last_published_at timestamp(0) without time zone,
    last_error character varying(255),
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    soa_mname character varying(255),
    soa_rname character varying(255),
    soa_refresh integer DEFAULT 3600 NOT NULL,
    soa_retry integer DEFAULT 600 NOT NULL,
    soa_expire integer DEFAULT 1209600 NOT NULL,
    soa_minimum integer DEFAULT 300 NOT NULL,
    force_https boolean DEFAULT false NOT NULL
);


--
-- Name: dns_zones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dns_zones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dns_zones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dns_zones_id_seq OWNED BY public.dns_zones.id;


--
-- Name: email_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_aliases (
    id bigint NOT NULL,
    alias_email character varying(255) NOT NULL,
    target_email character varying(255),
    user_id bigint NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    description character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_aliases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_aliases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_aliases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_aliases_id_seq OWNED BY public.email_aliases.id;


--
-- Name: email_auto_replies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_auto_replies (
    id bigint NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    subject character varying(255),
    body text NOT NULL,
    html_body text,
    start_date date,
    end_date date,
    only_contacts boolean DEFAULT false NOT NULL,
    exclude_mailing_lists boolean DEFAULT true NOT NULL,
    reply_once_per_sender boolean DEFAULT true NOT NULL,
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_auto_replies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_auto_replies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_auto_replies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_auto_replies_id_seq OWNED BY public.email_auto_replies.id;


--
-- Name: email_auto_reply_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_auto_reply_log (
    id bigint NOT NULL,
    sender_email character varying(255) NOT NULL,
    sent_at timestamp(0) without time zone NOT NULL,
    user_id bigint NOT NULL
);


--
-- Name: email_auto_reply_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_auto_reply_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_auto_reply_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_auto_reply_log_id_seq OWNED BY public.email_auto_reply_log.id;


--
-- Name: email_blocked_senders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_blocked_senders (
    id bigint NOT NULL,
    email character varying(255),
    domain character varying(255),
    reason character varying(255),
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_blocked_senders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_blocked_senders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_blocked_senders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_blocked_senders_id_seq OWNED BY public.email_blocked_senders.id;


--
-- Name: email_category_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_category_preferences (
    id bigint NOT NULL,
    email character varying(255),
    domain character varying(255),
    category character varying(255) NOT NULL,
    confidence double precision DEFAULT 0.7 NOT NULL,
    learned_count integer DEFAULT 1 NOT NULL,
    source character varying(255) DEFAULT 'manual_move'::character varying NOT NULL,
    last_learned_at timestamp(0) without time zone,
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT email_category_preferences_category_check CHECK (((category)::text = ANY ((ARRAY['feed'::character varying, 'ledger'::character varying])::text[]))),
    CONSTRAINT email_category_preferences_email_or_domain_check CHECK ((((email IS NOT NULL) AND (domain IS NULL)) OR ((email IS NULL) AND (domain IS NOT NULL))))
);


--
-- Name: email_category_preferences_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_category_preferences_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_category_preferences_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_category_preferences_id_seq OWNED BY public.email_category_preferences.id;


--
-- Name: email_custom_domains; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_custom_domains (
    id bigint NOT NULL,
    domain character varying(255) NOT NULL,
    verification_token character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    verified_at timestamp(0) without time zone,
    last_checked_at timestamp(0) without time zone,
    last_error character varying(255),
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    dkim_selector character varying(255) DEFAULT NULL::character varying,
    dkim_public_key text,
    dkim_private_key text,
    dkim_synced_at timestamp(0) without time zone,
    dkim_last_error character varying(255)
);


--
-- Name: email_custom_domains_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_custom_domains_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_custom_domains_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_custom_domains_id_seq OWNED BY public.email_custom_domains.id;


--
-- Name: email_exports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_exports (
    id bigint NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    format character varying(255) DEFAULT 'mbox'::character varying NOT NULL,
    file_path character varying(255),
    file_size integer,
    message_count integer,
    started_at timestamp(0) without time zone,
    completed_at timestamp(0) without time zone,
    error text,
    filters jsonb DEFAULT '{}'::jsonb,
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_exports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_exports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_exports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_exports_id_seq OWNED BY public.email_exports.id;


--
-- Name: email_filters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_filters (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    stop_processing boolean DEFAULT false NOT NULL,
    conditions jsonb DEFAULT '{}'::jsonb NOT NULL,
    actions jsonb DEFAULT '{}'::jsonb NOT NULL,
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_filters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_filters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_filters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_filters_id_seq OWNED BY public.email_filters.id;


--
-- Name: email_folders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_folders (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    color character varying(255),
    icon character varying(255),
    parent_id bigint,
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_folders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_folders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_folders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_folders_id_seq OWNED BY public.email_folders.id;


--
-- Name: email_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_jobs (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying,
    email_attrs jsonb NOT NULL,
    attachments jsonb,
    attempts integer DEFAULT 0,
    max_attempts integer DEFAULT 3,
    error character varying(255),
    completed_at timestamp(0) without time zone,
    scheduled_for timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_jobs_id_seq OWNED BY public.email_jobs.id;


--
-- Name: email_labels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_labels (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    color character varying(255) DEFAULT '#3b82f6'::character varying,
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_labels_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_labels_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_labels_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_labels_id_seq OWNED BY public.email_labels.id;


--
-- Name: email_message_labels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_message_labels (
    message_id bigint NOT NULL,
    label_id bigint NOT NULL
);


--
-- Name: email_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_messages (
    id bigint NOT NULL,
    message_id character varying(500) NOT NULL,
    "from" character varying(500) NOT NULL,
    "to" text,
    cc text,
    bcc text,
    subject character varying(500),
    text_body text,
    html_body text,
    status character varying(255) DEFAULT 'received'::character varying NOT NULL,
    read boolean DEFAULT false,
    metadata jsonb DEFAULT '{}'::jsonb,
    mailbox_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    category character varying(255) DEFAULT 'inbox'::character varying,
    stack_at timestamp(0) without time zone,
    stack_reason character varying(255),
    reply_later_at timestamp(0) without time zone,
    reply_later_reminder boolean DEFAULT false,
    is_receipt boolean DEFAULT false,
    is_notification boolean DEFAULT false,
    is_newsletter boolean DEFAULT false,
    opened_at timestamp(0) without time zone,
    first_opened_at timestamp(0) without time zone,
    open_count integer DEFAULT 0,
    spam boolean DEFAULT false,
    archived boolean DEFAULT false,
    attachments jsonb DEFAULT '{}'::jsonb,
    has_attachments boolean DEFAULT false,
    hash character varying(32),
    flagged boolean DEFAULT false NOT NULL,
    deleted boolean DEFAULT false NOT NULL,
    answered boolean DEFAULT false NOT NULL,
    encrypted_text_body jsonb,
    encrypted_html_body jsonb,
    search_index text[] DEFAULT ARRAY[]::text[],
    thread_id bigint,
    in_reply_to character varying(255),
    "references" text,
    jmap_blob_id character varying(255),
    priority character varying(255) DEFAULT 'normal'::character varying,
    folder_id bigint,
    scheduled_at timestamp(0) without time zone,
    expires_at timestamp(0) without time zone,
    undo_send_until timestamp(0) without time zone,
    client_encrypted_payload jsonb
);


--
-- Name: email_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_messages_id_seq OWNED BY public.email_messages.id;


--
-- Name: email_safe_senders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_safe_senders (
    id bigint NOT NULL,
    email character varying(255),
    domain character varying(255),
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_safe_senders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_safe_senders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_safe_senders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_safe_senders_id_seq OWNED BY public.email_safe_senders.id;


--
-- Name: email_submissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_submissions (
    id bigint NOT NULL,
    mailbox_id bigint NOT NULL,
    email_id bigint,
    identity_id character varying(255) NOT NULL,
    envelope_from character varying(255) NOT NULL,
    envelope_to character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    send_at timestamp(0) without time zone,
    undo_status character varying(255) DEFAULT 'pending'::character varying,
    delivery_status jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_submissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_submissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_submissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_submissions_id_seq OWNED BY public.email_submissions.id;


--
-- Name: email_suppressions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_suppressions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    email character varying(255) NOT NULL,
    reason character varying(255) NOT NULL,
    source character varying(255) DEFAULT 'manual'::character varying NOT NULL,
    note text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_event_at timestamp(0) without time zone NOT NULL,
    expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_suppressions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_suppressions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_suppressions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_suppressions_id_seq OWNED BY public.email_suppressions.id;


--
-- Name: email_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_templates (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    subject character varying(255),
    body text NOT NULL,
    html_body text,
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_templates_id_seq OWNED BY public.email_templates.id;


--
-- Name: email_threads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_threads (
    id bigint NOT NULL,
    mailbox_id bigint NOT NULL,
    subject_hash character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_threads_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_threads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_threads_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_threads_id_seq OWNED BY public.email_threads.id;


--
-- Name: email_unsubscribes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_unsubscribes (
    id bigint NOT NULL,
    email character varying(255) NOT NULL,
    user_id bigint,
    list_id character varying(255),
    token character varying(255) NOT NULL,
    unsubscribed_at timestamp(0) without time zone NOT NULL,
    ip_address character varying(255),
    user_agent text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: email_unsubscribes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_unsubscribes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_unsubscribes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_unsubscribes_id_seq OWNED BY public.email_unsubscribes.id;


--
-- Name: federated_boosts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.federated_boosts (
    id bigint NOT NULL,
    message_id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    activitypub_id character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: federated_boosts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.federated_boosts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: federated_boosts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.federated_boosts_id_seq OWNED BY public.federated_boosts.id;


--
-- Name: federated_dislikes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.federated_dislikes (
    id bigint NOT NULL,
    message_id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    activitypub_id character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: federated_dislikes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.federated_dislikes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: federated_dislikes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.federated_dislikes_id_seq OWNED BY public.federated_dislikes.id;


--
-- Name: federated_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.federated_likes (
    id bigint NOT NULL,
    message_id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    activitypub_id text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: federated_likes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.federated_likes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: federated_likes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.federated_likes_id_seq OWNED BY public.federated_likes.id;


--
-- Name: federated_quotes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.federated_quotes (
    id bigint NOT NULL,
    message_id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    activitypub_id character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: federated_quotes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.federated_quotes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: federated_quotes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.federated_quotes_id_seq OWNED BY public.federated_quotes.id;


--
-- Name: file_shares; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.file_shares (
    id bigint NOT NULL,
    stored_file_id bigint NOT NULL,
    user_id bigint NOT NULL,
    token character varying(255) NOT NULL,
    revoked_at timestamp(0) without time zone,
    download_count integer DEFAULT 0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    expires_at timestamp(0) without time zone,
    access_level character varying(255) DEFAULT 'download'::character varying NOT NULL,
    password_hash text
);


--
-- Name: file_shares_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.file_shares_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: file_shares_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.file_shares_id_seq OWNED BY public.file_shares.id;


--
-- Name: follows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.follows (
    id bigint NOT NULL,
    follower_id integer,
    followed_id integer,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    activitypub_id text,
    remote_actor_id bigint,
    pending boolean DEFAULT false
);


--
-- Name: follows_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.follows_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: follows_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.follows_id_seq OWNED BY public.follows.id;


--
-- Name: forwarded_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.forwarded_messages (
    id bigint NOT NULL,
    message_id character varying(255),
    from_address character varying(255),
    subject character varying(255),
    original_recipient character varying(255),
    final_recipient character varying(255),
    forwarding_chain jsonb,
    total_hops integer,
    alias_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: forwarded_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.forwarded_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: forwarded_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.forwarded_messages_id_seq OWNED BY public.forwarded_messages.id;


--
-- Name: friend_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.friend_requests (
    id bigint NOT NULL,
    requester_id bigint NOT NULL,
    recipient_id bigint NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    message text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: friend_requests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.friend_requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: friend_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.friend_requests_id_seq OWNED BY public.friend_requests.id;


--
-- Name: group_follows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_follows (
    id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    group_actor_id bigint NOT NULL,
    activitypub_id character varying(255),
    pending boolean DEFAULT false,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: group_follows_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.group_follows_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: group_follows_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.group_follows_id_seq OWNED BY public.group_follows.id;


--
-- Name: handle_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.handle_history (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    handle character varying(255) NOT NULL,
    used_from timestamp(0) without time zone NOT NULL,
    used_until timestamp(0) without time zone,
    reserved_until timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: handle_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.handle_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: handle_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.handle_history_id_seq OWNED BY public.handle_history.id;


--
-- Name: hashtag_follows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hashtag_follows (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    hashtag_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: hashtag_follows_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.hashtag_follows_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: hashtag_follows_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.hashtag_follows_id_seq OWNED BY public.hashtag_follows.id;


--
-- Name: hashtags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hashtags (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    normalized_name character varying(255) NOT NULL,
    use_count integer DEFAULT 0,
    last_used_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: hashtags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.hashtags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: hashtags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.hashtags_id_seq OWNED BY public.hashtags.id;


--
-- Name: imap_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.imap_subscriptions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    folder_name character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: imap_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.imap_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: imap_subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.imap_subscriptions_id_seq OWNED BY public.imap_subscriptions.id;


--
-- Name: invite_code_uses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invite_code_uses (
    id bigint NOT NULL,
    invite_code_id bigint NOT NULL,
    user_id bigint NOT NULL,
    used_at timestamp(0) without time zone DEFAULT now() NOT NULL
);


--
-- Name: invite_code_uses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.invite_code_uses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: invite_code_uses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.invite_code_uses_id_seq OWNED BY public.invite_code_uses.id;


--
-- Name: invite_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invite_codes (
    id bigint NOT NULL,
    code character varying(255) NOT NULL,
    max_uses integer DEFAULT 1,
    uses_count integer DEFAULT 0,
    expires_at timestamp(0) without time zone,
    created_by_id bigint,
    note text,
    is_active boolean DEFAULT true,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: invite_codes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.invite_codes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: invite_codes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.invite_codes_id_seq OWNED BY public.invite_codes.id;


--
-- Name: jmap_email_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jmap_email_changes (
    id bigint NOT NULL,
    mailbox_id bigint NOT NULL,
    email_id bigint NOT NULL,
    change_type character varying(255) NOT NULL,
    state_counter bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: jmap_email_changes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.jmap_email_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: jmap_email_changes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.jmap_email_changes_id_seq OWNED BY public.jmap_email_changes.id;


--
-- Name: jmap_email_tombstones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jmap_email_tombstones (
    id bigint NOT NULL,
    mailbox_id bigint NOT NULL,
    email_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: jmap_email_tombstones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.jmap_email_tombstones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: jmap_email_tombstones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.jmap_email_tombstones_id_seq OWNED BY public.jmap_email_tombstones.id;


--
-- Name: jmap_state_tracking; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jmap_state_tracking (
    id bigint NOT NULL,
    mailbox_id bigint NOT NULL,
    entity_type character varying(255) NOT NULL,
    state_counter bigint DEFAULT 0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: jmap_state_tracking_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.jmap_state_tracking_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: jmap_state_tracking_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.jmap_state_tracking_id_seq OWNED BY public.jmap_state_tracking.id;


--
-- Name: lemmy_counts_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lemmy_counts_cache (
    id bigint NOT NULL,
    activitypub_id text NOT NULL,
    upvotes integer DEFAULT 0,
    downvotes integer DEFAULT 0,
    score integer DEFAULT 0,
    comments integer DEFAULT 0,
    top_comments jsonb DEFAULT '[]'::jsonb,
    fetched_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: lemmy_counts_cache_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.lemmy_counts_cache_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: lemmy_counts_cache_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.lemmy_counts_cache_id_seq OWNED BY public.lemmy_counts_cache.id;


--
-- Name: link_preview_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.link_preview_jobs (
    id bigint NOT NULL,
    url character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying,
    message_id bigint,
    attempts integer DEFAULT 0,
    max_attempts integer DEFAULT 3,
    error character varying(255),
    link_preview_id bigint,
    completed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: link_preview_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.link_preview_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: link_preview_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.link_preview_jobs_id_seq OWNED BY public.link_preview_jobs.id;


--
-- Name: link_previews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.link_previews (
    id bigint NOT NULL,
    url text NOT NULL,
    title character varying(255),
    description text,
    image_url character varying(255),
    site_name character varying(255),
    favicon_url character varying(255),
    status character varying(255) DEFAULT 'pending'::character varying,
    error_message text,
    fetched_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: link_previews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.link_previews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: link_previews_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.link_previews_id_seq OWNED BY public.link_previews.id;


--
-- Name: list_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.list_members (
    id bigint NOT NULL,
    list_id bigint NOT NULL,
    user_id bigint,
    remote_actor_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT user_or_remote_actor CHECK ((((user_id IS NOT NULL) AND (remote_actor_id IS NULL)) OR ((user_id IS NULL) AND (remote_actor_id IS NOT NULL))))
);


--
-- Name: list_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.list_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: list_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.list_members_id_seq OWNED BY public.list_members.id;


--
-- Name: lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lists (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    visibility character varying(255) DEFAULT 'public'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: lists_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.lists_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: lists_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.lists_id_seq OWNED BY public.lists.id;


--
-- Name: mailboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mailboxes (
    id bigint NOT NULL,
    email character varying(255) NOT NULL,
    user_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    forward_to character varying(255),
    forward_enabled boolean DEFAULT false NOT NULL,
    username character varying(255),
    private_storage_enabled boolean DEFAULT false NOT NULL,
    private_storage_public_key text,
    private_storage_wrapped_private_key jsonb,
    private_storage_verifier jsonb
);


--
-- Name: mailboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mailboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mailboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mailboxes_id_seq OWNED BY public.mailboxes.id;


--
-- Name: message_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_reactions (
    id bigint NOT NULL,
    message_id bigint NOT NULL,
    user_id bigint,
    emoji character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    remote_actor_id bigint,
    federated boolean DEFAULT false,
    emoji_url character varying(255)
);


--
-- Name: message_reactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.message_reactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: message_reactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.message_reactions_id_seq OWNED BY public.message_reactions.id;


--
-- Name: message_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_votes (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    message_id bigint NOT NULL,
    vote_type character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: message_votes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.message_votes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: message_votes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.message_votes_id_seq OWNED BY public.message_votes.id;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id bigint NOT NULL,
    conversation_id integer,
    sender_id integer,
    content text,
    message_type character varying(255) DEFAULT 'text'::character varying,
    media_urls character varying(255)[] DEFAULT ARRAY[]::character varying[],
    reply_to_id bigint,
    edited_at timestamp(0) without time zone,
    deleted_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    visibility character varying(255) DEFAULT 'conversation'::character varying,
    post_type character varying(255) DEFAULT 'message'::character varying,
    like_count integer DEFAULT 0,
    reply_count integer DEFAULT 0,
    share_count integer DEFAULT 0,
    link_preview_id bigint,
    extracted_urls character varying(255)[] DEFAULT ARRAY[]::character varying[],
    extracted_hashtags character varying(255)[] DEFAULT ARRAY[]::character varying[],
    upvotes integer DEFAULT 0,
    downvotes integer DEFAULT 0,
    score integer DEFAULT 0,
    original_message_id bigint,
    shared_message_id bigint,
    promoted_from character varying(255),
    share_type character varying(255),
    title character varying(255),
    auto_title boolean DEFAULT false,
    promoted_from_community_name character varying(255),
    promoted_from_community_hash character varying(255),
    flair_id bigint,
    is_pinned boolean DEFAULT false,
    pinned_at timestamp(0) without time zone,
    pinned_by_id bigint,
    media_metadata jsonb DEFAULT '{}'::jsonb,
    encrypted_content jsonb,
    search_index text[] DEFAULT ARRAY[]::text[],
    primary_url text,
    locked_at timestamp(0) without time zone,
    locked_by_id bigint,
    lock_reason text,
    approval_status character varying(255),
    approved_by_id bigint,
    approved_at timestamp(0) without time zone,
    activitypub_id text,
    activitypub_url text,
    federated boolean DEFAULT false,
    remote_actor_id bigint,
    content_warning text,
    sensitive boolean DEFAULT false,
    dislike_count integer DEFAULT 0,
    quoted_message_id bigint,
    quote_count integer DEFAULT 0,
    category character varying(255),
    is_draft boolean DEFAULT false,
    scheduled_at timestamp(0) without time zone,
    bluesky_uri text,
    bluesky_cid character varying(255),
    activitypub_id_canonical text,
    activitypub_url_canonical text,
    CONSTRAINT messages_post_type_check CHECK (((post_type)::text = ANY ((ARRAY['message'::character varying, 'post'::character varying, 'comment'::character varying, 'share'::character varying, 'discussion'::character varying, 'link'::character varying, 'poll'::character varying, 'gallery'::character varying])::text[])))
);


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messages_id_seq OWNED BY public.messages.id;


--
-- Name: messaging_federation_account_presence_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_account_presence_states (
    id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    origin_domain character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    activities jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at_remote timestamp(0) without time zone NOT NULL,
    expires_at_remote timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_account_presence_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_account_presence_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_account_presence_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_account_presence_states_id_seq OWNED BY public.messaging_federation_account_presence_states.id;


--
-- Name: messaging_federation_call_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_call_sessions (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    local_user_id bigint NOT NULL,
    federated_call_id character varying(255) NOT NULL,
    origin_domain character varying(255) NOT NULL,
    remote_domain character varying(255) NOT NULL,
    remote_handle character varying(255) NOT NULL,
    remote_actor jsonb DEFAULT '{}'::jsonb NOT NULL,
    call_type character varying(255) NOT NULL,
    direction character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    started_at_remote timestamp(0) without time zone,
    ended_at_remote timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_call_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_call_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_call_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_call_sessions_id_seq OWNED BY public.messaging_federation_call_sessions.id;


--
-- Name: messaging_federation_discovered_peers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_discovered_peers (
    id bigint NOT NULL,
    domain character varying(255) NOT NULL,
    base_url character varying(255) NOT NULL,
    discovery_url character varying(255) NOT NULL,
    protocol character varying(255),
    protocol_id character varying(255),
    protocol_version character varying(255),
    trust_state character varying(255) DEFAULT 'trusted'::character varying NOT NULL,
    identity_fingerprint character varying(255) NOT NULL,
    previous_identity_fingerprint character varying(255),
    last_key_change_at timestamp(0) without time zone,
    identity jsonb DEFAULT '{}'::jsonb NOT NULL,
    endpoints jsonb DEFAULT '{}'::jsonb NOT NULL,
    features jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_discovered_at timestamp(0) without time zone NOT NULL,
    last_error text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_discovered_peers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_discovered_peers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_discovered_peers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_discovered_peers_id_seq OWNED BY public.messaging_federation_discovered_peers.id;


--
-- Name: messaging_federation_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_events (
    id bigint NOT NULL,
    event_id character varying(255) NOT NULL,
    origin_domain character varying(255) NOT NULL,
    event_type character varying(255) NOT NULL,
    stream_id character varying(255) NOT NULL,
    sequence bigint NOT NULL,
    payload jsonb NOT NULL,
    received_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    protocol_version character varying(255) DEFAULT '1.0'::character varying NOT NULL,
    idempotency_key character varying(255) NOT NULL
);


--
-- Name: messaging_federation_events_archive; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_events_archive (
    id bigint NOT NULL,
    event_id character varying(255) NOT NULL,
    origin_domain character varying(255) NOT NULL,
    event_type character varying(255) NOT NULL,
    stream_id character varying(255) NOT NULL,
    sequence bigint NOT NULL,
    payload jsonb NOT NULL,
    received_at timestamp(0) without time zone NOT NULL,
    partition_month date NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    protocol_version character varying(255) DEFAULT '1.0'::character varying NOT NULL,
    idempotency_key character varying(255) NOT NULL
);


--
-- Name: messaging_federation_events_archive_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_events_archive_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_events_archive_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_events_archive_id_seq OWNED BY public.messaging_federation_events_archive.id;


--
-- Name: messaging_federation_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_events_id_seq OWNED BY public.messaging_federation_events.id;


--
-- Name: messaging_federation_extension_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_extension_events (
    id bigint NOT NULL,
    event_type character varying(255) NOT NULL,
    origin_domain character varying(255) NOT NULL,
    event_key character varying(255) NOT NULL,
    status character varying(255),
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp(0) without time zone,
    server_id bigint,
    conversation_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_extension_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_extension_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_extension_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_extension_events_id_seq OWNED BY public.messaging_federation_extension_events.id;


--
-- Name: messaging_federation_invite_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_invite_states (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    origin_domain character varying(255) NOT NULL,
    actor_uri character varying(255) NOT NULL,
    actor_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    target_uri character varying(255) NOT NULL,
    target_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    role character varying(255) NOT NULL,
    state character varying(255) NOT NULL,
    invited_at_remote timestamp(0) without time zone,
    updated_at_remote timestamp(0) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_invite_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_invite_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_invite_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_invite_states_id_seq OWNED BY public.messaging_federation_invite_states.id;


--
-- Name: messaging_federation_membership_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_membership_states (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    origin_domain character varying(255) NOT NULL,
    role character varying(255) NOT NULL,
    state character varying(255) NOT NULL,
    joined_at_remote timestamp(0) without time zone,
    updated_at_remote timestamp(0) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_membership_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_membership_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_membership_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_membership_states_id_seq OWNED BY public.messaging_federation_membership_states.id;


--
-- Name: messaging_federation_outbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_outbox_events (
    id bigint NOT NULL,
    event_id character varying(255) NOT NULL,
    event_type character varying(255) NOT NULL,
    stream_id character varying(255) NOT NULL,
    sequence bigint NOT NULL,
    payload jsonb NOT NULL,
    target_domains character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    delivered_domains character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 8 NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    next_retry_at timestamp(0) without time zone NOT NULL,
    last_error text,
    partition_month date DEFAULT (date_trunc('month'::text, now()))::date NOT NULL,
    dispatched_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_outbox_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_outbox_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_outbox_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_outbox_events_id_seq OWNED BY public.messaging_federation_outbox_events.id;


--
-- Name: messaging_federation_peer_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_peer_policies (
    id bigint NOT NULL,
    domain character varying(255) NOT NULL,
    allow_incoming boolean,
    allow_outgoing boolean,
    blocked boolean DEFAULT false NOT NULL,
    reason text,
    updated_by_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_peer_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_peer_policies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_peer_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_peer_policies_id_seq OWNED BY public.messaging_federation_peer_policies.id;


--
-- Name: messaging_federation_presence_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_presence_states (
    id bigint NOT NULL,
    server_id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    origin_domain character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    activities jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at_remote timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    expires_at_remote timestamp(0) without time zone
);


--
-- Name: messaging_federation_presence_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_presence_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_presence_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_presence_states_id_seq OWNED BY public.messaging_federation_presence_states.id;


--
-- Name: messaging_federation_read_cursors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_read_cursors (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    chat_message_id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    origin_domain character varying(255) NOT NULL,
    read_at timestamp(0) without time zone NOT NULL,
    read_through_sequence integer,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_read_cursors_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_read_cursors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_read_cursors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_read_cursors_id_seq OWNED BY public.messaging_federation_read_cursors.id;


--
-- Name: messaging_federation_read_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_read_receipts (
    id bigint NOT NULL,
    chat_message_id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    origin_domain character varying(255) NOT NULL,
    read_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_read_receipts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_read_receipts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_read_receipts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_read_receipts_id_seq OWNED BY public.messaging_federation_read_receipts.id;


--
-- Name: messaging_federation_request_replays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_request_replays (
    id bigint NOT NULL,
    nonce character varying(255) NOT NULL,
    origin_domain character varying(255) NOT NULL,
    key_id character varying(255),
    http_method character varying(255) NOT NULL,
    request_path character varying(255) NOT NULL,
    "timestamp" bigint NOT NULL,
    seen_at timestamp(0) without time zone NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_request_replays_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_request_replays_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_request_replays_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_request_replays_id_seq OWNED BY public.messaging_federation_request_replays.id;


--
-- Name: messaging_federation_room_presence_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_room_presence_states (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    remote_actor_id bigint NOT NULL,
    origin_domain character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    activities jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at_remote timestamp(0) without time zone NOT NULL,
    expires_at_remote timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_room_presence_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_room_presence_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_room_presence_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_room_presence_states_id_seq OWNED BY public.messaging_federation_room_presence_states.id;


--
-- Name: messaging_federation_stream_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_stream_counters (
    id bigint NOT NULL,
    stream_id character varying(255) NOT NULL,
    next_sequence bigint DEFAULT 1 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_stream_counters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_stream_counters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_stream_counters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_stream_counters_id_seq OWNED BY public.messaging_federation_stream_counters.id;


--
-- Name: messaging_federation_stream_positions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_federation_stream_positions (
    id bigint NOT NULL,
    origin_domain character varying(255) NOT NULL,
    stream_id character varying(255) NOT NULL,
    last_sequence bigint DEFAULT 0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_federation_stream_positions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_federation_stream_positions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_federation_stream_positions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_federation_stream_positions_id_seq OWNED BY public.messaging_federation_stream_positions.id;


--
-- Name: messaging_server_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_server_members (
    id bigint NOT NULL,
    server_id bigint NOT NULL,
    user_id bigint NOT NULL,
    role character varying(255) DEFAULT 'member'::character varying NOT NULL,
    joined_at timestamp(0) without time zone DEFAULT now(),
    left_at timestamp(0) without time zone,
    notifications_enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: messaging_server_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_server_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_server_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_server_members_id_seq OWNED BY public.messaging_server_members.id;


--
-- Name: messaging_servers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messaging_servers (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    icon_url character varying(255),
    is_public boolean DEFAULT false NOT NULL,
    member_count integer DEFAULT 0 NOT NULL,
    last_activity_at timestamp(0) without time zone,
    creator_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    last_federated_at timestamp(0) without time zone,
    federation_id character varying(255),
    origin_domain character varying(255),
    is_federated_mirror boolean DEFAULT false NOT NULL
);


--
-- Name: messaging_servers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messaging_servers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messaging_servers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messaging_servers_id_seq OWNED BY public.messaging_servers.id;


--
-- Name: moderation_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.moderation_actions (
    id bigint NOT NULL,
    action_type character varying(255) NOT NULL,
    target_user_id bigint NOT NULL,
    moderator_id bigint NOT NULL,
    conversation_id bigint,
    reason character varying(255),
    duration integer,
    details jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    target_message_id bigint
);


--
-- Name: moderation_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.moderation_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: moderation_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.moderation_actions_id_seq OWNED BY public.moderation_actions.id;


--
-- Name: moderator_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.moderator_notes (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    target_user_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    note text NOT NULL,
    is_important boolean DEFAULT false,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: moderator_notes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.moderator_notes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: moderator_notes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.moderator_notes_id_seq OWNED BY public.moderator_notes.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id bigint NOT NULL,
    type character varying(255) NOT NULL,
    title character varying(255) NOT NULL,
    body text,
    url character varying(255),
    icon character varying(255),
    priority character varying(255) DEFAULT 'normal'::character varying,
    read_at timestamp(0) without time zone,
    seen_at timestamp(0) without time zone,
    dismissed_at timestamp(0) without time zone,
    user_id bigint NOT NULL,
    actor_id bigint,
    source_type character varying(255),
    source_id integer,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notifications_id_seq OWNED BY public.notifications.id;


--
-- Name: oauth_apps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_apps (
    id bigint NOT NULL,
    client_name character varying(255) NOT NULL,
    redirect_uris text NOT NULL,
    scopes character varying(255)[] DEFAULT ARRAY['read'::character varying] NOT NULL,
    website character varying(255),
    client_id character varying(255) NOT NULL,
    client_secret character varying(255) NOT NULL,
    trusted boolean DEFAULT false NOT NULL,
    user_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: oauth_apps_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oauth_apps_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oauth_apps_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oauth_apps_id_seq OWNED BY public.oauth_apps.id;


--
-- Name: oauth_authorizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_authorizations (
    id bigint NOT NULL,
    token character varying(255) NOT NULL,
    scopes character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    valid_until timestamp(0) without time zone NOT NULL,
    used boolean DEFAULT false NOT NULL,
    user_id bigint,
    app_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    redirect_uri text,
    state text,
    nonce text,
    code_challenge text,
    code_challenge_method character varying(255)
);


--
-- Name: oauth_authorizations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oauth_authorizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oauth_authorizations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oauth_authorizations_id_seq OWNED BY public.oauth_authorizations.id;


--
-- Name: oauth_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_tokens (
    id bigint NOT NULL,
    token character varying(255) NOT NULL,
    refresh_token character varying(255) NOT NULL,
    scopes character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    valid_until timestamp(0) without time zone NOT NULL,
    user_id bigint,
    app_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    oidc_nonce text,
    oidc_auth_time timestamp(0) without time zone
);


--
-- Name: oauth_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oauth_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oauth_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oauth_tokens_id_seq OWNED BY public.oauth_tokens.id;


--
-- Name: oban_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oban_jobs (
    id bigint NOT NULL,
    state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);


--
-- Name: TABLE oban_jobs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.oban_jobs IS '12';


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;


--
-- Name: oban_peers; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);


--
-- Name: oidc_signing_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oidc_signing_keys (
    id bigint NOT NULL,
    kid character varying(255) NOT NULL,
    alg character varying(255) DEFAULT 'RS256'::character varying NOT NULL,
    public_key_pem text NOT NULL,
    private_key_pem text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: oidc_signing_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oidc_signing_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oidc_signing_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oidc_signing_keys_id_seq OWNED BY public.oidc_signing_keys.id;


--
-- Name: passkey_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.passkey_credentials (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    credential_id bytea NOT NULL,
    public_key bytea NOT NULL,
    sign_count integer DEFAULT 0 NOT NULL,
    user_handle bytea NOT NULL,
    name character varying(255) DEFAULT 'Passkey'::character varying,
    aaguid bytea,
    transports character varying(255)[] DEFAULT ARRAY[]::character varying[],
    last_used_at timestamp(0) without time zone,
    created_from_ip character varying(255),
    created_user_agent character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: passkey_credentials_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.passkey_credentials_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: passkey_credentials_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.passkey_credentials_id_seq OWNED BY public.passkey_credentials.id;


--
-- Name: password_vault_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.password_vault_entries (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    title character varying(255) NOT NULL,
    login_username character varying(255),
    website character varying(255),
    encrypted_password jsonb NOT NULL,
    encrypted_notes jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: password_vault_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.password_vault_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: password_vault_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.password_vault_entries_id_seq OWNED BY public.password_vault_entries.id;


--
-- Name: password_vault_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.password_vault_settings (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    encrypted_verifier jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: password_vault_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.password_vault_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: password_vault_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.password_vault_settings_id_seq OWNED BY public.password_vault_settings.id;


--
-- Name: pgp_key_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pgp_key_cache (
    id bigint NOT NULL,
    email character varying(255) NOT NULL,
    public_key text,
    key_id character varying(255),
    fingerprint character varying(255),
    source character varying(255),
    status character varying(255) DEFAULT 'found'::character varying,
    expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: pgp_key_cache_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pgp_key_cache_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pgp_key_cache_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pgp_key_cache_id_seq OWNED BY public.pgp_key_cache.id;


--
-- Name: platform_updates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_updates (
    id bigint NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    badge character varying(255),
    items character varying(255)[] DEFAULT ARRAY[]::character varying[],
    published boolean DEFAULT true,
    created_by_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: platform_updates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.platform_updates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: platform_updates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.platform_updates_id_seq OWNED BY public.platform_updates.id;


--
-- Name: poll_options; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.poll_options (
    id bigint NOT NULL,
    poll_id bigint NOT NULL,
    option_text character varying(255) NOT NULL,
    "position" integer DEFAULT 0,
    vote_count integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: poll_options_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.poll_options_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: poll_options_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.poll_options_id_seq OWNED BY public.poll_options.id;


--
-- Name: poll_votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.poll_votes (
    id bigint NOT NULL,
    poll_id bigint NOT NULL,
    option_id bigint NOT NULL,
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: poll_votes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.poll_votes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: poll_votes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.poll_votes_id_seq OWNED BY public.poll_votes.id;


--
-- Name: polls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.polls (
    id bigint NOT NULL,
    message_id bigint NOT NULL,
    question text NOT NULL,
    closes_at timestamp(0) without time zone,
    allow_multiple boolean DEFAULT false,
    total_votes integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    voters_count integer DEFAULT 0,
    voter_uris character varying(255)[] DEFAULT ARRAY[]::character varying[],
    hide_totals boolean DEFAULT false NOT NULL,
    last_fetched_at timestamp(0) without time zone
);


--
-- Name: polls_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.polls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: polls_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.polls_id_seq OWNED BY public.polls.id;


--
-- Name: post_boosts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_boosts (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    message_id bigint NOT NULL,
    activitypub_id text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: post_boosts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.post_boosts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: post_boosts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.post_boosts_id_seq OWNED BY public.post_boosts.id;


--
-- Name: post_dismissals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_dismissals (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    message_id bigint NOT NULL,
    dismissal_type character varying(255) NOT NULL,
    dwell_time_ms integer,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: post_dismissals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.post_dismissals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: post_dismissals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.post_dismissals_id_seq OWNED BY public.post_dismissals.id;


--
-- Name: post_hashtags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_hashtags (
    id bigint NOT NULL,
    message_id bigint NOT NULL,
    hashtag_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: post_hashtags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.post_hashtags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: post_hashtags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.post_hashtags_id_seq OWNED BY public.post_hashtags.id;


--
-- Name: post_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_likes (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    message_id bigint NOT NULL,
    created_at timestamp(0) without time zone DEFAULT now() NOT NULL
);


--
-- Name: post_likes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.post_likes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: post_likes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.post_likes_id_seq OWNED BY public.post_likes.id;


--
-- Name: post_views; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_views (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    message_id bigint NOT NULL,
    view_duration_seconds integer,
    completed boolean DEFAULT false,
    inserted_at timestamp(0) without time zone NOT NULL,
    dwell_time_ms integer,
    scroll_depth double precision,
    expanded boolean DEFAULT false,
    source character varying(255)
);


--
-- Name: post_views_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.post_views_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: post_views_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.post_views_id_seq OWNED BY public.post_views.id;


--
-- Name: profile_custom_domains; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_custom_domains (
    id bigint NOT NULL,
    domain character varying(255) NOT NULL,
    verification_token character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    verified_at timestamp(0) without time zone,
    last_checked_at timestamp(0) without time zone,
    last_error character varying(255),
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: profile_custom_domains_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profile_custom_domains_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profile_custom_domains_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profile_custom_domains_id_seq OWNED BY public.profile_custom_domains.id;


--
-- Name: profile_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_links (
    id bigint NOT NULL,
    profile_id bigint NOT NULL,
    title character varying(255) NOT NULL,
    url character varying(255) NOT NULL,
    description character varying(255),
    icon character varying(255) DEFAULT 'hero-link'::character varying,
    platform character varying(255),
    "position" integer DEFAULT 0,
    clicks integer DEFAULT 0,
    is_active boolean DEFAULT true,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    section character varying(255),
    thumbnail_url character varying(255),
    display_style character varying(255),
    highlight_effect character varying(255)
);


--
-- Name: profile_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profile_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profile_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profile_links_id_seq OWNED BY public.profile_links.id;


--
-- Name: profile_site_visits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_site_visits (
    id bigint NOT NULL,
    profile_user_id bigint NOT NULL,
    viewer_user_id bigint,
    visitor_id character varying(255),
    ip_address character varying(255),
    user_agent text,
    referer text,
    request_host character varying(255) NOT NULL,
    request_path text NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: profile_site_visits_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profile_site_visits_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profile_site_visits_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profile_site_visits_id_seq OWNED BY public.profile_site_visits.id;


--
-- Name: profile_views; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_views (
    id bigint NOT NULL,
    profile_user_id bigint NOT NULL,
    viewer_user_id bigint,
    viewer_session_id character varying(255),
    ip_address character varying(255),
    user_agent text,
    referer text,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: profile_views_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profile_views_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profile_views_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profile_views_id_seq OWNED BY public.profile_views.id;


--
-- Name: profile_widgets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_widgets (
    id bigint NOT NULL,
    profile_id bigint NOT NULL,
    widget_type character varying(255) NOT NULL,
    title character varying(255),
    content text,
    url character varying(255),
    "position" integer DEFAULT 0,
    is_active boolean DEFAULT true,
    settings jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: profile_widgets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profile_widgets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profile_widgets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profile_widgets_id_seq OWNED BY public.profile_widgets.id;


--
-- Name: registration_checkouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.registration_checkouts (
    id bigint NOT NULL,
    stripe_checkout_session_id character varying(255) NOT NULL,
    lookup_token character varying(255) NOT NULL,
    product_slug character varying(255) NOT NULL,
    stripe_customer_id character varying(255),
    stripe_payment_intent_id character varying(255),
    customer_email character varying(255),
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    fulfilled_at timestamp(0) without time zone,
    invite_code_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    redeemed_at timestamp(0) without time zone,
    redeemed_by_user_id bigint
);


--
-- Name: registration_checkouts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.registration_checkouts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: registration_checkouts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.registration_checkouts_id_seq OWNED BY public.registration_checkouts.id;


--
-- Name: remote_interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.remote_interactions (
    id bigint NOT NULL,
    interaction_type character varying(255) NOT NULL,
    actor_uri character varying(255) NOT NULL,
    emoji character varying(255),
    message_id bigint NOT NULL,
    remote_actor_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: remote_interactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.remote_interactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: remote_interactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.remote_interactions_id_seq OWNED BY public.remote_interactions.id;


--
-- Name: reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reports (
    id bigint NOT NULL,
    reporter_id bigint NOT NULL,
    reportable_type character varying(255) NOT NULL,
    reportable_id integer NOT NULL,
    reason character varying(255) NOT NULL,
    description text,
    screenshots character varying(255)[] DEFAULT ARRAY[]::character varying[],
    status character varying(255) DEFAULT 'pending'::character varying,
    priority character varying(255) DEFAULT 'normal'::character varying,
    reviewed_by_id bigint,
    reviewed_at timestamp(0) without time zone,
    resolution_notes text,
    action_taken character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: reports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reports_id_seq OWNED BY public.reports.id;


--
-- Name: rss_feeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rss_feeds (
    id bigint NOT NULL,
    url text NOT NULL,
    title character varying(255),
    description text,
    site_url character varying(255),
    favicon_url character varying(255),
    image_url character varying(255),
    last_fetched_at timestamp(0) without time zone,
    last_error text,
    fetch_interval_minutes integer DEFAULT 60,
    status character varying(255) DEFAULT 'active'::character varying,
    etag character varying(255),
    last_modified character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: rss_feeds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rss_feeds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rss_feeds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rss_feeds_id_seq OWNED BY public.rss_feeds.id;


--
-- Name: rss_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rss_items (
    id bigint NOT NULL,
    feed_id bigint NOT NULL,
    guid character varying(255) NOT NULL,
    title character varying(255),
    content text,
    summary text,
    url text,
    author character varying(255),
    published_at timestamp(0) without time zone,
    image_url character varying(255),
    enclosure_url text,
    enclosure_type character varying(255),
    categories character varying(255)[] DEFAULT ARRAY[]::character varying[],
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: rss_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rss_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rss_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rss_items_id_seq OWNED BY public.rss_items.id;


--
-- Name: rss_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rss_subscriptions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    feed_id bigint NOT NULL,
    display_name character varying(255),
    folder character varying(255),
    notify_new_items boolean DEFAULT false,
    show_in_timeline boolean DEFAULT true,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: rss_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rss_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rss_subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rss_subscriptions_id_seq OWNED BY public.rss_subscriptions.id;


--
-- Name: saved_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.saved_items (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    message_id bigint,
    rss_item_id bigint,
    folder character varying(255),
    notes text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT saved_items_one_reference CHECK ((((message_id IS NOT NULL) AND (rss_item_id IS NULL)) OR ((message_id IS NULL) AND (rss_item_id IS NOT NULL))))
);


--
-- Name: saved_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.saved_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: saved_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.saved_items_id_seq OWNED BY public.saved_items.id;


--
-- Name: signing_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.signing_keys (
    key_id character varying(255) NOT NULL,
    user_id bigint,
    remote_actor_id bigint,
    public_key text NOT NULL,
    private_key text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT must_have_owner CHECK ((((user_id IS NOT NULL) AND (remote_actor_id IS NULL)) OR ((user_id IS NULL) AND (remote_actor_id IS NOT NULL))))
);


--
-- Name: static_site_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.static_site_files (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    path character varying(255) NOT NULL,
    storage_key character varying(255) NOT NULL,
    content_type character varying(255) NOT NULL,
    size integer NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: static_site_files_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.static_site_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: static_site_files_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.static_site_files_id_seq OWNED BY public.static_site_files.id;


--
-- Name: stored_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stored_files (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    path character varying(255) NOT NULL,
    storage_key character varying(255) NOT NULL,
    original_filename character varying(255) NOT NULL,
    content_type character varying(255) NOT NULL,
    size bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: stored_files_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stored_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stored_files_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stored_files_id_seq OWNED BY public.stored_files.id;


--
-- Name: stored_folders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stored_folders (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    path character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: stored_folders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stored_folders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stored_folders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stored_folders_id_seq OWNED BY public.stored_folders.id;


--
-- Name: subscription_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_products (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    description text,
    features character varying(255)[] DEFAULT ARRAY[]::character varying[],
    stripe_monthly_price_id character varying(255),
    stripe_yearly_price_id character varying(255),
    monthly_price_cents integer,
    yearly_price_cents integer,
    currency character varying(255) DEFAULT 'usd'::character varying,
    active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    billing_type character varying(255) DEFAULT 'recurring'::character varying NOT NULL,
    stripe_one_time_price_id character varying(255),
    one_time_price_cents integer
);


--
-- Name: subscription_products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.subscription_products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: subscription_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.subscription_products_id_seq OWNED BY public.subscription_products.id;


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    product character varying(255) NOT NULL,
    stripe_customer_id character varying(255),
    stripe_subscription_id character varying(255),
    stripe_price_id character varying(255),
    status character varying(255) DEFAULT 'incomplete'::character varying NOT NULL,
    current_period_start timestamp(0) without time zone,
    current_period_end timestamp(0) without time zone,
    canceled_at timestamp(0) without time zone,
    cancel_at_period_end boolean DEFAULT false,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.subscriptions_id_seq OWNED BY public.subscriptions.id;


--
-- Name: system_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_config (
    id bigint NOT NULL,
    key character varying(255) NOT NULL,
    value text,
    type character varying(255) DEFAULT 'string'::character varying,
    description text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: system_config_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.system_config_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: system_config_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.system_config_id_seq OWNED BY public.system_config.id;


--
-- Name: trust_level_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_level_logs (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    old_level integer NOT NULL,
    new_level integer NOT NULL,
    reason character varying(255),
    changed_by_user_id bigint,
    notes text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: trust_level_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.trust_level_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: trust_level_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.trust_level_logs_id_seq OWNED BY public.trust_level_logs.id;


--
-- Name: trusted_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trusted_devices (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    device_token character varying(255) NOT NULL,
    device_name character varying(255),
    user_agent character varying(255),
    ip_address character varying(255),
    last_used_at timestamp(0) without time zone,
    expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: trusted_devices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.trusted_devices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: trusted_devices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.trusted_devices_id_seq OWNED BY public.trusted_devices.id;


--
-- Name: user_activity_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_activity_stats (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    posts_created integer DEFAULT 0,
    topics_created integer DEFAULT 0,
    replies_created integer DEFAULT 0,
    likes_given integer DEFAULT 0,
    likes_received integer DEFAULT 0,
    replies_received integer DEFAULT 0,
    posts_read integer DEFAULT 0,
    topics_entered integer DEFAULT 0,
    time_read_seconds integer DEFAULT 0,
    days_visited integer DEFAULT 0,
    last_visit_date date,
    flags_given integer DEFAULT 0,
    flags_received integer DEFAULT 0,
    flags_agreed integer DEFAULT 0,
    posts_deleted integer DEFAULT 0,
    suspensions_count integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_activity_stats_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_activity_stats_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_activity_stats_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_activity_stats_id_seq OWNED BY public.user_activity_stats.id;


--
-- Name: user_badges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_badges (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    badge_type character varying(255) NOT NULL,
    badge_text character varying(255),
    badge_color character varying(255) DEFAULT '#8b5cf6'::character varying,
    badge_icon character varying(255),
    tooltip character varying(255),
    granted_by_id bigint,
    "position" integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    visible boolean DEFAULT true
);


--
-- Name: user_badges_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_badges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_badges_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_badges_id_seq OWNED BY public.user_badges.id;


--
-- Name: user_blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_blocks (
    id bigint NOT NULL,
    blocker_id bigint NOT NULL,
    blocked_id bigint NOT NULL,
    reason character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_blocks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_blocks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_blocks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_blocks_id_seq OWNED BY public.user_blocks.id;


--
-- Name: user_hidden_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_hidden_messages (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    message_id bigint NOT NULL,
    hidden_at timestamp(0) without time zone DEFAULT now(),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_hidden_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_hidden_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_hidden_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_hidden_messages_id_seq OWNED BY public.user_hidden_messages.id;


--
-- Name: user_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_integrations (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    provider character varying(255) NOT NULL,
    provider_user_id character varying(255),
    username character varying(255),
    avatar_url character varying(255),
    access_token bytea,
    refresh_token bytea,
    token_expires_at timestamp(0) without time zone,
    scopes character varying(255)[] DEFAULT ARRAY[]::character varying[],
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_integrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_integrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_integrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_integrations_id_seq OWNED BY public.user_integrations.id;


--
-- Name: user_mutes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_mutes (
    id bigint NOT NULL,
    muter_id bigint NOT NULL,
    muted_id bigint NOT NULL,
    mute_notifications boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_mutes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_mutes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_mutes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_mutes_id_seq OWNED BY public.user_mutes.id;


--
-- Name: user_post_timestamps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_post_timestamps (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    user_id bigint NOT NULL,
    last_post_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_post_timestamps_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_post_timestamps_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_post_timestamps_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_post_timestamps_id_seq OWNED BY public.user_post_timestamps.id;


--
-- Name: user_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_profiles (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    display_name character varying(255),
    description text,
    theme character varying(255) DEFAULT 'purple'::character varying,
    accent_color character varying(255) DEFAULT '#8b5cf6'::character varying,
    font_family character varying(255),
    cursor_style character varying(255) DEFAULT 'default'::character varying,
    avatar_url character varying(255),
    banner_url character varying(255),
    background_url character varying(255),
    background_type character varying(255) DEFAULT 'gradient'::character varying,
    music_url character varying(255),
    music_title character varying(255),
    discord_user_id character varying(255),
    show_discord_presence boolean DEFAULT false,
    is_public boolean DEFAULT true,
    page_views integer DEFAULT 0,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    location character varying(255),
    page_title character varying(255),
    favicon_url character varying(255),
    text_color character varying(255) DEFAULT '#ffffff'::character varying,
    background_color character varying(255) DEFAULT '#000000'::character varying,
    icon_color character varying(255) DEFAULT '#ffffff'::character varying,
    profile_opacity double precision DEFAULT 1.0,
    profile_blur integer DEFAULT 0,
    monochrome_icons boolean DEFAULT false,
    volume_control boolean DEFAULT false,
    use_discord_avatar boolean DEFAULT false,
    hide_view_counter boolean DEFAULT false,
    hide_uid boolean DEFAULT false,
    avatar_size integer DEFAULT 0,
    banner_size integer DEFAULT 0,
    background_size integer DEFAULT 0,
    username_effect character varying(255) DEFAULT 'none'::character varying,
    username_glow_color character varying(255) DEFAULT '#8b5cf6'::character varying,
    username_glow_intensity integer DEFAULT 10,
    username_shadow_color character varying(255) DEFAULT '#000000'::character varying,
    username_gradient_from character varying(255),
    username_gradient_to character varying(255),
    username_animation_speed character varying(255) DEFAULT 'normal'::character varying,
    typewriter_effect boolean DEFAULT false,
    typewriter_speed character varying(255) DEFAULT 'normal'::character varying,
    typewriter_title boolean DEFAULT false,
    link_display_style character varying(255) DEFAULT 'circular'::character varying,
    container_background_color character varying(255),
    container_opacity double precision DEFAULT 0.4,
    container_pattern character varying(255) DEFAULT 'none'::character varying,
    pattern_color character varying(255),
    pattern_animated boolean DEFAULT false,
    pattern_animation_speed character varying(255) DEFAULT 'normal'::character varying,
    hide_followers boolean DEFAULT false,
    hide_avatar boolean DEFAULT false,
    hide_timeline boolean DEFAULT false,
    text_background boolean DEFAULT false,
    pattern_opacity double precision DEFAULT 0.2,
    avatar_effect character varying(255) DEFAULT 'none'::character varying,
    tick_color character varying(255) DEFAULT '#1d9bf0'::character varying,
    hide_share_button boolean DEFAULT false,
    extend_layout boolean DEFAULT true NOT NULL,
    hide_community_posts boolean DEFAULT false NOT NULL,
    link_highlight_effect character varying(255) DEFAULT 'none'::character varying NOT NULL,
    circular_links_position character varying(255) DEFAULT 'top'::character varying NOT NULL,
    profile_mode character varying(255) DEFAULT 'builder'::character varying NOT NULL,
    static_site_index character varying(255)
);


--
-- Name: user_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_profiles_id_seq OWNED BY public.user_profiles.id;


--
-- Name: user_timeouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_timeouts (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    conversation_id bigint,
    timeout_until timestamp(0) without time zone NOT NULL,
    reason character varying(255),
    created_by_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_timeouts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_timeouts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_timeouts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_timeouts_id_seq OWNED BY public.user_timeouts.id;


--
-- Name: user_warnings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_warnings (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    user_id bigint NOT NULL,
    warned_by_id bigint NOT NULL,
    reason text NOT NULL,
    severity character varying(255) DEFAULT 'low'::character varying,
    acknowledged_at timestamp(0) without time zone,
    related_message_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: user_warnings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_warnings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_warnings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_warnings_id_seq OWNED BY public.user_warnings.id;


--
-- Name: username_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.username_history (
    id bigint NOT NULL,
    username character varying(255) NOT NULL,
    user_id bigint NOT NULL,
    changed_at timestamp(0) without time zone NOT NULL,
    previous_username character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: username_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.username_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: username_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.username_history_id_seq OWNED BY public.username_history.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    username character varying(255) NOT NULL,
    password_hash character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    avatar character varying(255),
    is_admin boolean DEFAULT false NOT NULL,
    banned boolean DEFAULT false NOT NULL,
    banned_at timestamp(0) without time zone,
    banned_reason character varying(255),
    two_factor_enabled boolean DEFAULT false NOT NULL,
    two_factor_secret character varying(255),
    two_factor_backup_codes character varying(255)[],
    two_factor_enabled_at timestamp(0) without time zone,
    registration_ip text,
    last_login_ip text,
    last_login_at timestamp(0) without time zone,
    login_count integer DEFAULT 0,
    display_name character varying(100),
    recovery_email character varying(255),
    password_reset_token character varying(255),
    password_reset_token_expires_at timestamp(0) without time zone,
    locale character varying(5) DEFAULT 'en'::character varying,
    last_password_change timestamp(0) without time zone,
    suspended boolean DEFAULT false NOT NULL,
    suspended_until timestamp(0) without time zone,
    suspension_reason text,
    handle character varying(255),
    unique_id character varying(255),
    handle_changed_at timestamp(0) without time zone,
    allow_group_adds_from character varying(255) DEFAULT 'everyone'::character varying,
    allow_direct_messages_from character varying(255) DEFAULT 'everyone'::character varying,
    allow_mentions_from character varying(255) DEFAULT 'everyone'::character varying,
    profile_visibility character varying(255) DEFAULT 'public'::character varying,
    notify_on_new_follower boolean DEFAULT true,
    notify_on_direct_message boolean DEFAULT true,
    notify_on_mention boolean DEFAULT true,
    storage_used_bytes bigint DEFAULT 0 NOT NULL,
    storage_limit_bytes bigint DEFAULT 524288000 NOT NULL,
    storage_last_calculated_at timestamp(0) without time zone,
    avatar_size integer DEFAULT 0,
    timezone character varying(255),
    time_format character varying(255) DEFAULT '12'::character varying,
    last_imap_access timestamp(0) without time zone,
    last_pop3_access timestamp(0) without time zone,
    status character varying(255) DEFAULT 'online'::character varying NOT NULL,
    status_message character varying(255),
    status_updated_at timestamp(0) without time zone,
    last_seen_at timestamp(0) without time zone,
    verified boolean DEFAULT false,
    allow_calls_from character varying(255) DEFAULT 'friends'::character varying,
    allow_friend_requests_from character varying(255) DEFAULT 'everyone'::character varying,
    default_post_visibility character varying(255) DEFAULT 'followers'::character varying,
    onboarding_completed boolean DEFAULT false,
    onboarding_completed_at timestamp(0) without time zone,
    onboarding_step integer DEFAULT 1,
    email_signature text,
    trust_level integer DEFAULT 0 NOT NULL,
    trust_level_locked boolean DEFAULT false,
    promoted_at timestamp(0) without time zone,
    notify_on_reply boolean DEFAULT true,
    notify_on_like boolean DEFAULT true,
    notify_on_email_received boolean DEFAULT true,
    notify_on_discussion_reply boolean DEFAULT true,
    notify_on_comment boolean DEFAULT true,
    preferred_email_domain character varying(255) DEFAULT 'example.com'::character varying,
    activitypub_enabled boolean DEFAULT true,
    activitypub_private_key text,
    activitypub_public_key text,
    activitypub_manually_approve_followers boolean DEFAULT true,
    email_sending_restricted boolean DEFAULT false,
    email_rate_limit_violations integer DEFAULT 0,
    email_restriction_reason character varying(255),
    email_restricted_at timestamp(0) without time zone,
    recovery_email_verified boolean DEFAULT false,
    recovery_email_verification_token character varying(255),
    recovery_email_verification_sent_at timestamp(0) without time zone,
    addressbook_ctag character varying(255),
    pgp_public_key text,
    pgp_key_id character varying(255),
    pgp_fingerprint character varying(255),
    pgp_key_uploaded_at timestamp(0) without time zone,
    registered_via_onion boolean DEFAULT false NOT NULL,
    pgp_wkd_hash character varying(255),
    bluesky_enabled boolean DEFAULT false NOT NULL,
    bluesky_identifier character varying(255),
    bluesky_app_password text,
    bluesky_did character varying(255),
    bluesky_pds_url character varying(255),
    bluesky_inbound_cursor text,
    bluesky_inbound_last_polled_at timestamp(0) without time zone,
    stripe_customer_id character varying(255),
    theme_overrides jsonb DEFAULT '{}'::jsonb NOT NULL,
    auth_valid_after timestamp(0) without time zone,
    built_in_subdomain_mode character varying(255) DEFAULT 'platform'::character varying NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: vpn_connection_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vpn_connection_logs (
    id bigint NOT NULL,
    vpn_user_config_id bigint NOT NULL,
    connected_at timestamp(0) without time zone NOT NULL,
    disconnected_at timestamp(0) without time zone,
    bytes_sent bigint DEFAULT 0,
    bytes_received bigint DEFAULT 0,
    client_ip character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: vpn_connection_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.vpn_connection_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: vpn_connection_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.vpn_connection_logs_id_seq OWNED BY public.vpn_connection_logs.id;


--
-- Name: vpn_servers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vpn_servers (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    location character varying(255) NOT NULL,
    country_code character varying(2),
    city character varying(255),
    public_ip character varying(255) NOT NULL,
    public_key character varying(255) NOT NULL,
    endpoint_port integer DEFAULT 443 NOT NULL,
    internal_ip_range character varying(255) NOT NULL,
    dns_servers character varying(255) DEFAULT '1.1.1.1, 1.0.0.1'::character varying,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    max_users integer DEFAULT 100,
    current_users integer DEFAULT 0,
    api_endpoint character varying(255),
    api_key character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    minimum_trust_level integer DEFAULT 0 NOT NULL,
    endpoint_host character varying(255),
    client_mtu integer DEFAULT 1280
);


--
-- Name: vpn_servers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.vpn_servers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: vpn_servers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.vpn_servers_id_seq OWNED BY public.vpn_servers.id;


--
-- Name: vpn_user_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vpn_user_configs (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    vpn_server_id bigint NOT NULL,
    public_key character varying(255) NOT NULL,
    private_key bytea,
    allocated_ip character varying(255) NOT NULL,
    allowed_ips character varying(255) DEFAULT '0.0.0.0/0, ::/0'::character varying,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    last_handshake_at timestamp(0) without time zone,
    bytes_sent bigint DEFAULT 0,
    bytes_received bigint DEFAULT 0,
    persistent_keepalive integer DEFAULT 25,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    bandwidth_quota_bytes bigint DEFAULT '10737418240'::bigint NOT NULL,
    quota_period_start timestamp(0) without time zone,
    quota_used_bytes bigint DEFAULT 0 NOT NULL,
    rate_limit_mbps integer DEFAULT 50 NOT NULL
);


--
-- Name: vpn_user_configs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.vpn_user_configs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: vpn_user_configs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.vpn_user_configs_id_seq OWNED BY public.vpn_user_configs.id;


--
-- Name: account_deletion_requests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_deletion_requests ALTER COLUMN id SET DEFAULT nextval('public.account_deletion_requests_id_seq'::regclass);


--
-- Name: activitypub_activities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_activities ALTER COLUMN id SET DEFAULT nextval('public.activitypub_activities_id_seq'::regclass);


--
-- Name: activitypub_actors id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_actors ALTER COLUMN id SET DEFAULT nextval('public.activitypub_actors_id_seq'::regclass);


--
-- Name: activitypub_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_deliveries ALTER COLUMN id SET DEFAULT nextval('public.activitypub_deliveries_id_seq'::regclass);


--
-- Name: activitypub_instances id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_instances ALTER COLUMN id SET DEFAULT nextval('public.activitypub_instances_id_seq'::regclass);


--
-- Name: activitypub_relay_subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_relay_subscriptions ALTER COLUMN id SET DEFAULT nextval('public.activitypub_relay_subscriptions_id_seq'::regclass);


--
-- Name: activitypub_user_blocks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_user_blocks ALTER COLUMN id SET DEFAULT nextval('public.activitypub_user_blocks_id_seq'::regclass);


--
-- Name: announcement_dismissals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcement_dismissals ALTER COLUMN id SET DEFAULT nextval('public.announcement_dismissals_id_seq'::regclass);


--
-- Name: announcements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcements ALTER COLUMN id SET DEFAULT nextval('public.announcements_id_seq'::regclass);


--
-- Name: api_token_revocations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_token_revocations ALTER COLUMN id SET DEFAULT nextval('public.api_token_revocations_id_seq'::regclass);


--
-- Name: api_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens ALTER COLUMN id SET DEFAULT nextval('public.api_tokens_id_seq'::regclass);


--
-- Name: app_passwords id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_passwords ALTER COLUMN id SET DEFAULT nextval('public.app_passwords_id_seq'::regclass);


--
-- Name: audit_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs ALTER COLUMN id SET DEFAULT nextval('public.audit_logs_id_seq'::regclass);


--
-- Name: auto_mod_rules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auto_mod_rules ALTER COLUMN id SET DEFAULT nextval('public.auto_mod_rules_id_seq'::regclass);


--
-- Name: bluesky_inbound_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bluesky_inbound_events ALTER COLUMN id SET DEFAULT nextval('public.bluesky_inbound_events_id_seq'::regclass);


--
-- Name: calendar_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_events ALTER COLUMN id SET DEFAULT nextval('public.calendar_events_id_seq'::regclass);


--
-- Name: calendars id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendars ALTER COLUMN id SET DEFAULT nextval('public.calendars_id_seq'::regclass);


--
-- Name: calls id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calls ALTER COLUMN id SET DEFAULT nextval('public.calls_id_seq'::regclass);


--
-- Name: chat_conversation_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversation_members ALTER COLUMN id SET DEFAULT nextval('public.chat_conversation_members_id_seq'::regclass);


--
-- Name: chat_conversations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations ALTER COLUMN id SET DEFAULT nextval('public.chat_conversations_id_seq'::regclass);


--
-- Name: chat_message_reactions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_reactions ALTER COLUMN id SET DEFAULT nextval('public.chat_message_reactions_id_seq'::regclass);


--
-- Name: chat_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages ALTER COLUMN id SET DEFAULT nextval('public.chat_messages_id_seq'::regclass);


--
-- Name: chat_moderation_actions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_moderation_actions ALTER COLUMN id SET DEFAULT nextval('public.chat_moderation_actions_id_seq'::regclass);


--
-- Name: chat_user_hidden_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_user_hidden_messages ALTER COLUMN id SET DEFAULT nextval('public.chat_user_hidden_messages_id_seq'::regclass);


--
-- Name: chat_user_timeouts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_user_timeouts ALTER COLUMN id SET DEFAULT nextval('public.chat_user_timeouts_id_seq'::regclass);


--
-- Name: community_bans id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_bans ALTER COLUMN id SET DEFAULT nextval('public.community_bans_id_seq'::regclass);


--
-- Name: community_flairs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_flairs ALTER COLUMN id SET DEFAULT nextval('public.community_flairs_id_seq'::regclass);


--
-- Name: contact_groups id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_groups ALTER COLUMN id SET DEFAULT nextval('public.contact_groups_id_seq'::regclass);


--
-- Name: contacts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts ALTER COLUMN id SET DEFAULT nextval('public.contacts_id_seq'::regclass);


--
-- Name: conversation_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members ALTER COLUMN id SET DEFAULT nextval('public.conversation_members_id_seq'::regclass);


--
-- Name: conversations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations ALTER COLUMN id SET DEFAULT nextval('public.conversations_id_seq'::regclass);


--
-- Name: creator_satisfaction id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creator_satisfaction ALTER COLUMN id SET DEFAULT nextval('public.creator_satisfaction_id_seq'::regclass);


--
-- Name: custom_emojis id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.custom_emojis ALTER COLUMN id SET DEFAULT nextval('public.custom_emojis_id_seq'::regclass);


--
-- Name: data_exports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_exports ALTER COLUMN id SET DEFAULT nextval('public.data_exports_id_seq'::regclass);


--
-- Name: developer_webhook_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.developer_webhook_deliveries ALTER COLUMN id SET DEFAULT nextval('public.developer_webhook_deliveries_id_seq'::regclass);


--
-- Name: developer_webhooks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.developer_webhooks ALTER COLUMN id SET DEFAULT nextval('public.developer_webhooks_id_seq'::regclass);


--
-- Name: device_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tokens ALTER COLUMN id SET DEFAULT nextval('public.device_tokens_id_seq'::regclass);


--
-- Name: dns_query_stats id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_query_stats ALTER COLUMN id SET DEFAULT nextval('public.dns_query_stats_id_seq'::regclass);


--
-- Name: dns_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_records ALTER COLUMN id SET DEFAULT nextval('public.dns_records_id_seq'::regclass);


--
-- Name: dns_zone_service_configs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zone_service_configs ALTER COLUMN id SET DEFAULT nextval('public.dns_zone_service_configs_id_seq'::regclass);


--
-- Name: dns_zones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zones ALTER COLUMN id SET DEFAULT nextval('public.dns_zones_id_seq'::regclass);


--
-- Name: email_aliases id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_aliases ALTER COLUMN id SET DEFAULT nextval('public.email_aliases_id_seq'::regclass);


--
-- Name: email_auto_replies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_auto_replies ALTER COLUMN id SET DEFAULT nextval('public.email_auto_replies_id_seq'::regclass);


--
-- Name: email_auto_reply_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_auto_reply_log ALTER COLUMN id SET DEFAULT nextval('public.email_auto_reply_log_id_seq'::regclass);


--
-- Name: email_blocked_senders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_blocked_senders ALTER COLUMN id SET DEFAULT nextval('public.email_blocked_senders_id_seq'::regclass);


--
-- Name: email_category_preferences id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_category_preferences ALTER COLUMN id SET DEFAULT nextval('public.email_category_preferences_id_seq'::regclass);


--
-- Name: email_custom_domains id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_custom_domains ALTER COLUMN id SET DEFAULT nextval('public.email_custom_domains_id_seq'::regclass);


--
-- Name: email_exports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_exports ALTER COLUMN id SET DEFAULT nextval('public.email_exports_id_seq'::regclass);


--
-- Name: email_filters id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_filters ALTER COLUMN id SET DEFAULT nextval('public.email_filters_id_seq'::regclass);


--
-- Name: email_folders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_folders ALTER COLUMN id SET DEFAULT nextval('public.email_folders_id_seq'::regclass);


--
-- Name: email_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_jobs ALTER COLUMN id SET DEFAULT nextval('public.email_jobs_id_seq'::regclass);


--
-- Name: email_labels id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_labels ALTER COLUMN id SET DEFAULT nextval('public.email_labels_id_seq'::regclass);


--
-- Name: email_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_messages ALTER COLUMN id SET DEFAULT nextval('public.email_messages_id_seq'::regclass);


--
-- Name: email_safe_senders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_safe_senders ALTER COLUMN id SET DEFAULT nextval('public.email_safe_senders_id_seq'::regclass);


--
-- Name: email_submissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_submissions ALTER COLUMN id SET DEFAULT nextval('public.email_submissions_id_seq'::regclass);


--
-- Name: email_suppressions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_suppressions ALTER COLUMN id SET DEFAULT nextval('public.email_suppressions_id_seq'::regclass);


--
-- Name: email_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates ALTER COLUMN id SET DEFAULT nextval('public.email_templates_id_seq'::regclass);


--
-- Name: email_threads id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_threads ALTER COLUMN id SET DEFAULT nextval('public.email_threads_id_seq'::regclass);


--
-- Name: email_unsubscribes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_unsubscribes ALTER COLUMN id SET DEFAULT nextval('public.email_unsubscribes_id_seq'::regclass);


--
-- Name: federated_boosts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_boosts ALTER COLUMN id SET DEFAULT nextval('public.federated_boosts_id_seq'::regclass);


--
-- Name: federated_dislikes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_dislikes ALTER COLUMN id SET DEFAULT nextval('public.federated_dislikes_id_seq'::regclass);


--
-- Name: federated_likes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_likes ALTER COLUMN id SET DEFAULT nextval('public.federated_likes_id_seq'::regclass);


--
-- Name: federated_quotes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_quotes ALTER COLUMN id SET DEFAULT nextval('public.federated_quotes_id_seq'::regclass);


--
-- Name: file_shares id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_shares ALTER COLUMN id SET DEFAULT nextval('public.file_shares_id_seq'::regclass);


--
-- Name: follows id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows ALTER COLUMN id SET DEFAULT nextval('public.follows_id_seq'::regclass);


--
-- Name: forwarded_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forwarded_messages ALTER COLUMN id SET DEFAULT nextval('public.forwarded_messages_id_seq'::regclass);


--
-- Name: friend_requests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friend_requests ALTER COLUMN id SET DEFAULT nextval('public.friend_requests_id_seq'::regclass);


--
-- Name: group_follows id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_follows ALTER COLUMN id SET DEFAULT nextval('public.group_follows_id_seq'::regclass);


--
-- Name: handle_history id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handle_history ALTER COLUMN id SET DEFAULT nextval('public.handle_history_id_seq'::regclass);


--
-- Name: hashtag_follows id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hashtag_follows ALTER COLUMN id SET DEFAULT nextval('public.hashtag_follows_id_seq'::regclass);


--
-- Name: hashtags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hashtags ALTER COLUMN id SET DEFAULT nextval('public.hashtags_id_seq'::regclass);


--
-- Name: imap_subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imap_subscriptions ALTER COLUMN id SET DEFAULT nextval('public.imap_subscriptions_id_seq'::regclass);


--
-- Name: invite_code_uses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_code_uses ALTER COLUMN id SET DEFAULT nextval('public.invite_code_uses_id_seq'::regclass);


--
-- Name: invite_codes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_codes ALTER COLUMN id SET DEFAULT nextval('public.invite_codes_id_seq'::regclass);


--
-- Name: jmap_email_changes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jmap_email_changes ALTER COLUMN id SET DEFAULT nextval('public.jmap_email_changes_id_seq'::regclass);


--
-- Name: jmap_email_tombstones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jmap_email_tombstones ALTER COLUMN id SET DEFAULT nextval('public.jmap_email_tombstones_id_seq'::regclass);


--
-- Name: jmap_state_tracking id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jmap_state_tracking ALTER COLUMN id SET DEFAULT nextval('public.jmap_state_tracking_id_seq'::regclass);


--
-- Name: lemmy_counts_cache id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lemmy_counts_cache ALTER COLUMN id SET DEFAULT nextval('public.lemmy_counts_cache_id_seq'::regclass);


--
-- Name: link_preview_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_preview_jobs ALTER COLUMN id SET DEFAULT nextval('public.link_preview_jobs_id_seq'::regclass);


--
-- Name: link_previews id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_previews ALTER COLUMN id SET DEFAULT nextval('public.link_previews_id_seq'::regclass);


--
-- Name: list_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.list_members ALTER COLUMN id SET DEFAULT nextval('public.list_members_id_seq'::regclass);


--
-- Name: lists id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lists ALTER COLUMN id SET DEFAULT nextval('public.lists_id_seq'::regclass);


--
-- Name: mailboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mailboxes ALTER COLUMN id SET DEFAULT nextval('public.mailboxes_id_seq'::regclass);


--
-- Name: message_reactions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_reactions ALTER COLUMN id SET DEFAULT nextval('public.message_reactions_id_seq'::regclass);


--
-- Name: message_votes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_votes ALTER COLUMN id SET DEFAULT nextval('public.message_votes_id_seq'::regclass);


--
-- Name: messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages ALTER COLUMN id SET DEFAULT nextval('public.messages_id_seq'::regclass);


--
-- Name: messaging_federation_account_presence_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_account_presence_states ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_account_presence_states_id_seq'::regclass);


--
-- Name: messaging_federation_call_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_call_sessions ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_call_sessions_id_seq'::regclass);


--
-- Name: messaging_federation_discovered_peers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_discovered_peers ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_discovered_peers_id_seq'::regclass);


--
-- Name: messaging_federation_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_events ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_events_id_seq'::regclass);


--
-- Name: messaging_federation_events_archive id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_events_archive ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_events_archive_id_seq'::regclass);


--
-- Name: messaging_federation_extension_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_extension_events ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_extension_events_id_seq'::regclass);


--
-- Name: messaging_federation_invite_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_invite_states ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_invite_states_id_seq'::regclass);


--
-- Name: messaging_federation_membership_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_membership_states ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_membership_states_id_seq'::regclass);


--
-- Name: messaging_federation_outbox_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_outbox_events ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_outbox_events_id_seq'::regclass);


--
-- Name: messaging_federation_peer_policies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_peer_policies ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_peer_policies_id_seq'::regclass);


--
-- Name: messaging_federation_presence_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_presence_states ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_presence_states_id_seq'::regclass);


--
-- Name: messaging_federation_read_cursors id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_read_cursors ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_read_cursors_id_seq'::regclass);


--
-- Name: messaging_federation_read_receipts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_read_receipts ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_read_receipts_id_seq'::regclass);


--
-- Name: messaging_federation_request_replays id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_request_replays ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_request_replays_id_seq'::regclass);


--
-- Name: messaging_federation_room_presence_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_room_presence_states ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_room_presence_states_id_seq'::regclass);


--
-- Name: messaging_federation_stream_counters id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_stream_counters ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_stream_counters_id_seq'::regclass);


--
-- Name: messaging_federation_stream_positions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_stream_positions ALTER COLUMN id SET DEFAULT nextval('public.messaging_federation_stream_positions_id_seq'::regclass);


--
-- Name: messaging_server_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_server_members ALTER COLUMN id SET DEFAULT nextval('public.messaging_server_members_id_seq'::regclass);


--
-- Name: messaging_servers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_servers ALTER COLUMN id SET DEFAULT nextval('public.messaging_servers_id_seq'::regclass);


--
-- Name: moderation_actions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions ALTER COLUMN id SET DEFAULT nextval('public.moderation_actions_id_seq'::regclass);


--
-- Name: moderator_notes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_notes ALTER COLUMN id SET DEFAULT nextval('public.moderator_notes_id_seq'::regclass);


--
-- Name: notifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications ALTER COLUMN id SET DEFAULT nextval('public.notifications_id_seq'::regclass);


--
-- Name: oauth_apps id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_apps ALTER COLUMN id SET DEFAULT nextval('public.oauth_apps_id_seq'::regclass);


--
-- Name: oauth_authorizations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_authorizations ALTER COLUMN id SET DEFAULT nextval('public.oauth_authorizations_id_seq'::regclass);


--
-- Name: oauth_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_tokens ALTER COLUMN id SET DEFAULT nextval('public.oauth_tokens_id_seq'::regclass);


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: oidc_signing_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_signing_keys ALTER COLUMN id SET DEFAULT nextval('public.oidc_signing_keys_id_seq'::regclass);


--
-- Name: passkey_credentials id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passkey_credentials ALTER COLUMN id SET DEFAULT nextval('public.passkey_credentials_id_seq'::regclass);


--
-- Name: password_vault_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_vault_entries ALTER COLUMN id SET DEFAULT nextval('public.password_vault_entries_id_seq'::regclass);


--
-- Name: password_vault_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_vault_settings ALTER COLUMN id SET DEFAULT nextval('public.password_vault_settings_id_seq'::regclass);


--
-- Name: pgp_key_cache id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pgp_key_cache ALTER COLUMN id SET DEFAULT nextval('public.pgp_key_cache_id_seq'::regclass);


--
-- Name: platform_updates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_updates ALTER COLUMN id SET DEFAULT nextval('public.platform_updates_id_seq'::regclass);


--
-- Name: poll_options id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_options ALTER COLUMN id SET DEFAULT nextval('public.poll_options_id_seq'::regclass);


--
-- Name: poll_votes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_votes ALTER COLUMN id SET DEFAULT nextval('public.poll_votes_id_seq'::regclass);


--
-- Name: polls id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.polls ALTER COLUMN id SET DEFAULT nextval('public.polls_id_seq'::regclass);


--
-- Name: post_boosts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_boosts ALTER COLUMN id SET DEFAULT nextval('public.post_boosts_id_seq'::regclass);


--
-- Name: post_dismissals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_dismissals ALTER COLUMN id SET DEFAULT nextval('public.post_dismissals_id_seq'::regclass);


--
-- Name: post_hashtags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_hashtags ALTER COLUMN id SET DEFAULT nextval('public.post_hashtags_id_seq'::regclass);


--
-- Name: post_likes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_likes ALTER COLUMN id SET DEFAULT nextval('public.post_likes_id_seq'::regclass);


--
-- Name: post_views id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views ALTER COLUMN id SET DEFAULT nextval('public.post_views_id_seq'::regclass);


--
-- Name: profile_custom_domains id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_custom_domains ALTER COLUMN id SET DEFAULT nextval('public.profile_custom_domains_id_seq'::regclass);


--
-- Name: profile_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_links ALTER COLUMN id SET DEFAULT nextval('public.profile_links_id_seq'::regclass);


--
-- Name: profile_site_visits id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_site_visits ALTER COLUMN id SET DEFAULT nextval('public.profile_site_visits_id_seq'::regclass);


--
-- Name: profile_views id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_views ALTER COLUMN id SET DEFAULT nextval('public.profile_views_id_seq'::regclass);


--
-- Name: profile_widgets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_widgets ALTER COLUMN id SET DEFAULT nextval('public.profile_widgets_id_seq'::regclass);


--
-- Name: registration_checkouts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.registration_checkouts ALTER COLUMN id SET DEFAULT nextval('public.registration_checkouts_id_seq'::regclass);


--
-- Name: remote_interactions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.remote_interactions ALTER COLUMN id SET DEFAULT nextval('public.remote_interactions_id_seq'::regclass);


--
-- Name: reports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports ALTER COLUMN id SET DEFAULT nextval('public.reports_id_seq'::regclass);


--
-- Name: rss_feeds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rss_feeds ALTER COLUMN id SET DEFAULT nextval('public.rss_feeds_id_seq'::regclass);


--
-- Name: rss_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rss_items ALTER COLUMN id SET DEFAULT nextval('public.rss_items_id_seq'::regclass);


--
-- Name: rss_subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rss_subscriptions ALTER COLUMN id SET DEFAULT nextval('public.rss_subscriptions_id_seq'::regclass);


--
-- Name: saved_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_items ALTER COLUMN id SET DEFAULT nextval('public.saved_items_id_seq'::regclass);


--
-- Name: static_site_files id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.static_site_files ALTER COLUMN id SET DEFAULT nextval('public.static_site_files_id_seq'::regclass);


--
-- Name: stored_files id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_files ALTER COLUMN id SET DEFAULT nextval('public.stored_files_id_seq'::regclass);


--
-- Name: stored_folders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_folders ALTER COLUMN id SET DEFAULT nextval('public.stored_folders_id_seq'::regclass);


--
-- Name: subscription_products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_products ALTER COLUMN id SET DEFAULT nextval('public.subscription_products_id_seq'::regclass);


--
-- Name: subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions ALTER COLUMN id SET DEFAULT nextval('public.subscriptions_id_seq'::regclass);


--
-- Name: system_config id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_config ALTER COLUMN id SET DEFAULT nextval('public.system_config_id_seq'::regclass);


--
-- Name: trust_level_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_level_logs ALTER COLUMN id SET DEFAULT nextval('public.trust_level_logs_id_seq'::regclass);


--
-- Name: trusted_devices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trusted_devices ALTER COLUMN id SET DEFAULT nextval('public.trusted_devices_id_seq'::regclass);


--
-- Name: user_activity_stats id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_activity_stats ALTER COLUMN id SET DEFAULT nextval('public.user_activity_stats_id_seq'::regclass);


--
-- Name: user_badges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_badges ALTER COLUMN id SET DEFAULT nextval('public.user_badges_id_seq'::regclass);


--
-- Name: user_blocks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks ALTER COLUMN id SET DEFAULT nextval('public.user_blocks_id_seq'::regclass);


--
-- Name: user_hidden_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_hidden_messages ALTER COLUMN id SET DEFAULT nextval('public.user_hidden_messages_id_seq'::regclass);


--
-- Name: user_integrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_integrations ALTER COLUMN id SET DEFAULT nextval('public.user_integrations_id_seq'::regclass);


--
-- Name: user_mutes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_mutes ALTER COLUMN id SET DEFAULT nextval('public.user_mutes_id_seq'::regclass);


--
-- Name: user_post_timestamps id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_post_timestamps ALTER COLUMN id SET DEFAULT nextval('public.user_post_timestamps_id_seq'::regclass);


--
-- Name: user_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles ALTER COLUMN id SET DEFAULT nextval('public.user_profiles_id_seq'::regclass);


--
-- Name: user_timeouts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_timeouts ALTER COLUMN id SET DEFAULT nextval('public.user_timeouts_id_seq'::regclass);


--
-- Name: user_warnings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_warnings ALTER COLUMN id SET DEFAULT nextval('public.user_warnings_id_seq'::regclass);


--
-- Name: username_history id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.username_history ALTER COLUMN id SET DEFAULT nextval('public.username_history_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: vpn_connection_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vpn_connection_logs ALTER COLUMN id SET DEFAULT nextval('public.vpn_connection_logs_id_seq'::regclass);


--
-- Name: vpn_servers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vpn_servers ALTER COLUMN id SET DEFAULT nextval('public.vpn_servers_id_seq'::regclass);


--
-- Name: vpn_user_configs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vpn_user_configs ALTER COLUMN id SET DEFAULT nextval('public.vpn_user_configs_id_seq'::regclass);


--
-- Name: account_deletion_requests account_deletion_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_deletion_requests
    ADD CONSTRAINT account_deletion_requests_pkey PRIMARY KEY (id);


--
-- Name: activitypub_activities activitypub_activities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_activities
    ADD CONSTRAINT activitypub_activities_pkey PRIMARY KEY (id);


--
-- Name: activitypub_actors activitypub_actors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_actors
    ADD CONSTRAINT activitypub_actors_pkey PRIMARY KEY (id);


--
-- Name: activitypub_deliveries activitypub_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_deliveries
    ADD CONSTRAINT activitypub_deliveries_pkey PRIMARY KEY (id);


--
-- Name: activitypub_instances activitypub_instances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_instances
    ADD CONSTRAINT activitypub_instances_pkey PRIMARY KEY (id);


--
-- Name: activitypub_relay_subscriptions activitypub_relay_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_relay_subscriptions
    ADD CONSTRAINT activitypub_relay_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: activitypub_user_blocks activitypub_user_blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_user_blocks
    ADD CONSTRAINT activitypub_user_blocks_pkey PRIMARY KEY (id);


--
-- Name: announcement_dismissals announcement_dismissals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcement_dismissals
    ADD CONSTRAINT announcement_dismissals_pkey PRIMARY KEY (id);


--
-- Name: announcements announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_pkey PRIMARY KEY (id);


--
-- Name: api_token_revocations api_token_revocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_token_revocations
    ADD CONSTRAINT api_token_revocations_pkey PRIMARY KEY (id);


--
-- Name: api_tokens api_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens
    ADD CONSTRAINT api_tokens_pkey PRIMARY KEY (id);


--
-- Name: app_passwords app_passwords_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_passwords
    ADD CONSTRAINT app_passwords_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: auto_mod_rules auto_mod_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auto_mod_rules
    ADD CONSTRAINT auto_mod_rules_pkey PRIMARY KEY (id);


--
-- Name: bluesky_inbound_events bluesky_inbound_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bluesky_inbound_events
    ADD CONSTRAINT bluesky_inbound_events_pkey PRIMARY KEY (id);


--
-- Name: calendar_events calendar_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_events
    ADD CONSTRAINT calendar_events_pkey PRIMARY KEY (id);


--
-- Name: calendars calendars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendars
    ADD CONSTRAINT calendars_pkey PRIMARY KEY (id);


--
-- Name: calls calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calls
    ADD CONSTRAINT calls_pkey PRIMARY KEY (id);


--
-- Name: chat_conversation_members chat_conversation_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversation_members
    ADD CONSTRAINT chat_conversation_members_pkey PRIMARY KEY (id);


--
-- Name: chat_conversations chat_conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_pkey PRIMARY KEY (id);


--
-- Name: chat_message_reactions chat_message_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_reactions
    ADD CONSTRAINT chat_message_reactions_pkey PRIMARY KEY (id);


--
-- Name: chat_messages chat_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);


--
-- Name: chat_moderation_actions chat_moderation_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_moderation_actions
    ADD CONSTRAINT chat_moderation_actions_pkey PRIMARY KEY (id);


--
-- Name: chat_user_hidden_messages chat_user_hidden_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_user_hidden_messages
    ADD CONSTRAINT chat_user_hidden_messages_pkey PRIMARY KEY (id);


--
-- Name: chat_user_timeouts chat_user_timeouts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_user_timeouts
    ADD CONSTRAINT chat_user_timeouts_pkey PRIMARY KEY (id);


--
-- Name: community_bans community_bans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_bans
    ADD CONSTRAINT community_bans_pkey PRIMARY KEY (id);


--
-- Name: community_flairs community_flairs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_flairs
    ADD CONSTRAINT community_flairs_pkey PRIMARY KEY (id);


--
-- Name: contact_groups contact_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_groups
    ADD CONSTRAINT contact_groups_pkey PRIMARY KEY (id);


--
-- Name: contacts contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_pkey PRIMARY KEY (id);


--
-- Name: conversation_members conversation_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members
    ADD CONSTRAINT conversation_members_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: creator_satisfaction creator_satisfaction_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creator_satisfaction
    ADD CONSTRAINT creator_satisfaction_pkey PRIMARY KEY (id);


--
-- Name: custom_emojis custom_emojis_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.custom_emojis
    ADD CONSTRAINT custom_emojis_pkey PRIMARY KEY (id);


--
-- Name: data_exports data_exports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_exports
    ADD CONSTRAINT data_exports_pkey PRIMARY KEY (id);


--
-- Name: developer_webhook_deliveries developer_webhook_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.developer_webhook_deliveries
    ADD CONSTRAINT developer_webhook_deliveries_pkey PRIMARY KEY (id);


--
-- Name: developer_webhooks developer_webhooks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.developer_webhooks
    ADD CONSTRAINT developer_webhooks_pkey PRIMARY KEY (id);


--
-- Name: device_tokens device_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_pkey PRIMARY KEY (id);


--
-- Name: dns_query_stats dns_query_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_query_stats
    ADD CONSTRAINT dns_query_stats_pkey PRIMARY KEY (id);


--
-- Name: dns_records dns_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_records
    ADD CONSTRAINT dns_records_pkey PRIMARY KEY (id);


--
-- Name: dns_zone_service_configs dns_zone_service_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zone_service_configs
    ADD CONSTRAINT dns_zone_service_configs_pkey PRIMARY KEY (id);


--
-- Name: dns_zones dns_zones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zones
    ADD CONSTRAINT dns_zones_pkey PRIMARY KEY (id);


--
-- Name: email_aliases email_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_aliases
    ADD CONSTRAINT email_aliases_pkey PRIMARY KEY (id);


--
-- Name: email_auto_replies email_auto_replies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_auto_replies
    ADD CONSTRAINT email_auto_replies_pkey PRIMARY KEY (id);


--
-- Name: email_auto_reply_log email_auto_reply_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_auto_reply_log
    ADD CONSTRAINT email_auto_reply_log_pkey PRIMARY KEY (id);


--
-- Name: email_blocked_senders email_blocked_senders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_blocked_senders
    ADD CONSTRAINT email_blocked_senders_pkey PRIMARY KEY (id);


--
-- Name: email_category_preferences email_category_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_category_preferences
    ADD CONSTRAINT email_category_preferences_pkey PRIMARY KEY (id);


--
-- Name: email_custom_domains email_custom_domains_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_custom_domains
    ADD CONSTRAINT email_custom_domains_pkey PRIMARY KEY (id);


--
-- Name: email_exports email_exports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_exports
    ADD CONSTRAINT email_exports_pkey PRIMARY KEY (id);


--
-- Name: email_filters email_filters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_filters
    ADD CONSTRAINT email_filters_pkey PRIMARY KEY (id);


--
-- Name: email_folders email_folders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_folders
    ADD CONSTRAINT email_folders_pkey PRIMARY KEY (id);


--
-- Name: email_jobs email_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_jobs
    ADD CONSTRAINT email_jobs_pkey PRIMARY KEY (id);


--
-- Name: email_labels email_labels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_labels
    ADD CONSTRAINT email_labels_pkey PRIMARY KEY (id);


--
-- Name: email_messages email_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_messages
    ADD CONSTRAINT email_messages_pkey PRIMARY KEY (id);


--
-- Name: email_safe_senders email_safe_senders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_safe_senders
    ADD CONSTRAINT email_safe_senders_pkey PRIMARY KEY (id);


--
-- Name: email_submissions email_submissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_submissions
    ADD CONSTRAINT email_submissions_pkey PRIMARY KEY (id);


--
-- Name: email_suppressions email_suppressions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_suppressions
    ADD CONSTRAINT email_suppressions_pkey PRIMARY KEY (id);


--
-- Name: email_templates email_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates
    ADD CONSTRAINT email_templates_pkey PRIMARY KEY (id);


--
-- Name: email_threads email_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_threads
    ADD CONSTRAINT email_threads_pkey PRIMARY KEY (id);


--
-- Name: email_unsubscribes email_unsubscribes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_unsubscribes
    ADD CONSTRAINT email_unsubscribes_pkey PRIMARY KEY (id);


--
-- Name: federated_boosts federated_boosts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_boosts
    ADD CONSTRAINT federated_boosts_pkey PRIMARY KEY (id);


--
-- Name: federated_dislikes federated_dislikes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_dislikes
    ADD CONSTRAINT federated_dislikes_pkey PRIMARY KEY (id);


--
-- Name: federated_likes federated_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_likes
    ADD CONSTRAINT federated_likes_pkey PRIMARY KEY (id);


--
-- Name: federated_quotes federated_quotes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_quotes
    ADD CONSTRAINT federated_quotes_pkey PRIMARY KEY (id);


--
-- Name: file_shares file_shares_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_shares
    ADD CONSTRAINT file_shares_pkey PRIMARY KEY (id);


--
-- Name: follows follows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_pkey PRIMARY KEY (id);


--
-- Name: forwarded_messages forwarded_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forwarded_messages
    ADD CONSTRAINT forwarded_messages_pkey PRIMARY KEY (id);


--
-- Name: friend_requests friend_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friend_requests
    ADD CONSTRAINT friend_requests_pkey PRIMARY KEY (id);


--
-- Name: group_follows group_follows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_follows
    ADD CONSTRAINT group_follows_pkey PRIMARY KEY (id);


--
-- Name: handle_history handle_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handle_history
    ADD CONSTRAINT handle_history_pkey PRIMARY KEY (id);


--
-- Name: hashtag_follows hashtag_follows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hashtag_follows
    ADD CONSTRAINT hashtag_follows_pkey PRIMARY KEY (id);


--
-- Name: hashtags hashtags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hashtags
    ADD CONSTRAINT hashtags_pkey PRIMARY KEY (id);


--
-- Name: imap_subscriptions imap_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imap_subscriptions
    ADD CONSTRAINT imap_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: invite_code_uses invite_code_uses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_code_uses
    ADD CONSTRAINT invite_code_uses_pkey PRIMARY KEY (id);


--
-- Name: invite_codes invite_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_codes
    ADD CONSTRAINT invite_codes_pkey PRIMARY KEY (id);


--
-- Name: jmap_email_changes jmap_email_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jmap_email_changes
    ADD CONSTRAINT jmap_email_changes_pkey PRIMARY KEY (id);


--
-- Name: jmap_email_tombstones jmap_email_tombstones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jmap_email_tombstones
    ADD CONSTRAINT jmap_email_tombstones_pkey PRIMARY KEY (id);


--
-- Name: jmap_state_tracking jmap_state_tracking_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jmap_state_tracking
    ADD CONSTRAINT jmap_state_tracking_pkey PRIMARY KEY (id);


--
-- Name: lemmy_counts_cache lemmy_counts_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lemmy_counts_cache
    ADD CONSTRAINT lemmy_counts_cache_pkey PRIMARY KEY (id);


--
-- Name: link_preview_jobs link_preview_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_preview_jobs
    ADD CONSTRAINT link_preview_jobs_pkey PRIMARY KEY (id);


--
-- Name: link_previews link_previews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_previews
    ADD CONSTRAINT link_previews_pkey PRIMARY KEY (id);


--
-- Name: list_members list_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.list_members
    ADD CONSTRAINT list_members_pkey PRIMARY KEY (id);


--
-- Name: lists lists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT lists_pkey PRIMARY KEY (id);


--
-- Name: mailboxes mailboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mailboxes
    ADD CONSTRAINT mailboxes_pkey PRIMARY KEY (id);


--
-- Name: message_reactions message_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_reactions
    ADD CONSTRAINT message_reactions_pkey PRIMARY KEY (id);


--
-- Name: message_votes message_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_votes
    ADD CONSTRAINT message_votes_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_account_presence_states messaging_federation_account_presence_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_account_presence_states
    ADD CONSTRAINT messaging_federation_account_presence_states_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_call_sessions messaging_federation_call_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_call_sessions
    ADD CONSTRAINT messaging_federation_call_sessions_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_discovered_peers messaging_federation_discovered_peers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_discovered_peers
    ADD CONSTRAINT messaging_federation_discovered_peers_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_events_archive messaging_federation_events_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_events_archive
    ADD CONSTRAINT messaging_federation_events_archive_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_events messaging_federation_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_events
    ADD CONSTRAINT messaging_federation_events_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_extension_events messaging_federation_extension_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_extension_events
    ADD CONSTRAINT messaging_federation_extension_events_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_invite_states messaging_federation_invite_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_invite_states
    ADD CONSTRAINT messaging_federation_invite_states_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_membership_states messaging_federation_membership_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_membership_states
    ADD CONSTRAINT messaging_federation_membership_states_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_outbox_events messaging_federation_outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_outbox_events
    ADD CONSTRAINT messaging_federation_outbox_events_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_peer_policies messaging_federation_peer_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_peer_policies
    ADD CONSTRAINT messaging_federation_peer_policies_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_presence_states messaging_federation_presence_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_presence_states
    ADD CONSTRAINT messaging_federation_presence_states_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_read_cursors messaging_federation_read_cursors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_read_cursors
    ADD CONSTRAINT messaging_federation_read_cursors_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_read_receipts messaging_federation_read_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_read_receipts
    ADD CONSTRAINT messaging_federation_read_receipts_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_request_replays messaging_federation_request_replays_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_request_replays
    ADD CONSTRAINT messaging_federation_request_replays_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_room_presence_states messaging_federation_room_presence_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_room_presence_states
    ADD CONSTRAINT messaging_federation_room_presence_states_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_stream_counters messaging_federation_stream_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_stream_counters
    ADD CONSTRAINT messaging_federation_stream_counters_pkey PRIMARY KEY (id);


--
-- Name: messaging_federation_stream_positions messaging_federation_stream_positions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_stream_positions
    ADD CONSTRAINT messaging_federation_stream_positions_pkey PRIMARY KEY (id);


--
-- Name: messaging_server_members messaging_server_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_server_members
    ADD CONSTRAINT messaging_server_members_pkey PRIMARY KEY (id);


--
-- Name: messaging_servers messaging_servers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_servers
    ADD CONSTRAINT messaging_servers_pkey PRIMARY KEY (id);


--
-- Name: moderation_actions moderation_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions
    ADD CONSTRAINT moderation_actions_pkey PRIMARY KEY (id);


--
-- Name: moderator_notes moderator_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_notes
    ADD CONSTRAINT moderator_notes_pkey PRIMARY KEY (id);


--
-- Name: oban_jobs non_negative_priority; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: oauth_apps oauth_apps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_apps
    ADD CONSTRAINT oauth_apps_pkey PRIMARY KEY (id);


--
-- Name: oauth_authorizations oauth_authorizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_authorizations
    ADD CONSTRAINT oauth_authorizations_pkey PRIMARY KEY (id);


--
-- Name: oauth_tokens oauth_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_tokens
    ADD CONSTRAINT oauth_tokens_pkey PRIMARY KEY (id);


--
-- Name: oban_jobs oban_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);


--
-- Name: oban_peers oban_peers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);


--
-- Name: oidc_signing_keys oidc_signing_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_signing_keys
    ADD CONSTRAINT oidc_signing_keys_pkey PRIMARY KEY (id);


--
-- Name: passkey_credentials passkey_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passkey_credentials
    ADD CONSTRAINT passkey_credentials_pkey PRIMARY KEY (id);


--
-- Name: password_vault_entries password_vault_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_vault_entries
    ADD CONSTRAINT password_vault_entries_pkey PRIMARY KEY (id);


--
-- Name: password_vault_settings password_vault_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_vault_settings
    ADD CONSTRAINT password_vault_settings_pkey PRIMARY KEY (id);


--
-- Name: pgp_key_cache pgp_key_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pgp_key_cache
    ADD CONSTRAINT pgp_key_cache_pkey PRIMARY KEY (id);


--
-- Name: platform_updates platform_updates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_updates
    ADD CONSTRAINT platform_updates_pkey PRIMARY KEY (id);


--
-- Name: poll_options poll_options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_options
    ADD CONSTRAINT poll_options_pkey PRIMARY KEY (id);


--
-- Name: poll_votes poll_votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_votes
    ADD CONSTRAINT poll_votes_pkey PRIMARY KEY (id);


--
-- Name: polls polls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.polls
    ADD CONSTRAINT polls_pkey PRIMARY KEY (id);


--
-- Name: post_boosts post_boosts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_boosts
    ADD CONSTRAINT post_boosts_pkey PRIMARY KEY (id);


--
-- Name: post_dismissals post_dismissals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_dismissals
    ADD CONSTRAINT post_dismissals_pkey PRIMARY KEY (id);


--
-- Name: post_hashtags post_hashtags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_hashtags
    ADD CONSTRAINT post_hashtags_pkey PRIMARY KEY (id);


--
-- Name: post_likes post_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_likes
    ADD CONSTRAINT post_likes_pkey PRIMARY KEY (id);


--
-- Name: post_views post_views_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views
    ADD CONSTRAINT post_views_pkey PRIMARY KEY (id);


--
-- Name: profile_custom_domains profile_custom_domains_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_custom_domains
    ADD CONSTRAINT profile_custom_domains_pkey PRIMARY KEY (id);


--
-- Name: profile_links profile_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_links
    ADD CONSTRAINT profile_links_pkey PRIMARY KEY (id);


--
-- Name: profile_site_visits profile_site_visits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_site_visits
    ADD CONSTRAINT profile_site_visits_pkey PRIMARY KEY (id);


--
-- Name: profile_views profile_views_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_views
    ADD CONSTRAINT profile_views_pkey PRIMARY KEY (id);


--
-- Name: profile_widgets profile_widgets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_widgets
    ADD CONSTRAINT profile_widgets_pkey PRIMARY KEY (id);


--
-- Name: registration_checkouts registration_checkouts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.registration_checkouts
    ADD CONSTRAINT registration_checkouts_pkey PRIMARY KEY (id);


--
-- Name: remote_interactions remote_interactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.remote_interactions
    ADD CONSTRAINT remote_interactions_pkey PRIMARY KEY (id);


--
-- Name: reports reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_pkey PRIMARY KEY (id);


--
-- Name: rss_feeds rss_feeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rss_feeds
    ADD CONSTRAINT rss_feeds_pkey PRIMARY KEY (id);


--
-- Name: rss_items rss_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rss_items
    ADD CONSTRAINT rss_items_pkey PRIMARY KEY (id);


--
-- Name: rss_subscriptions rss_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rss_subscriptions
    ADD CONSTRAINT rss_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: saved_items saved_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_items
    ADD CONSTRAINT saved_items_pkey PRIMARY KEY (id);


--
-- Name: signing_keys signing_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.signing_keys
    ADD CONSTRAINT signing_keys_pkey PRIMARY KEY (key_id);


--
-- Name: static_site_files static_site_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.static_site_files
    ADD CONSTRAINT static_site_files_pkey PRIMARY KEY (id);


--
-- Name: stored_files stored_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_files
    ADD CONSTRAINT stored_files_pkey PRIMARY KEY (id);


--
-- Name: stored_folders stored_folders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_folders
    ADD CONSTRAINT stored_folders_pkey PRIMARY KEY (id);


--
-- Name: subscription_products subscription_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_products
    ADD CONSTRAINT subscription_products_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: system_config system_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_config
    ADD CONSTRAINT system_config_pkey PRIMARY KEY (id);


--
-- Name: trust_level_logs trust_level_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_level_logs
    ADD CONSTRAINT trust_level_logs_pkey PRIMARY KEY (id);


--
-- Name: trusted_devices trusted_devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trusted_devices
    ADD CONSTRAINT trusted_devices_pkey PRIMARY KEY (id);


--
-- Name: user_activity_stats user_activity_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_activity_stats
    ADD CONSTRAINT user_activity_stats_pkey PRIMARY KEY (id);


--
-- Name: user_badges user_badges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_badges
    ADD CONSTRAINT user_badges_pkey PRIMARY KEY (id);


--
-- Name: user_blocks user_blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_pkey PRIMARY KEY (id);


--
-- Name: user_hidden_messages user_hidden_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_hidden_messages
    ADD CONSTRAINT user_hidden_messages_pkey PRIMARY KEY (id);


--
-- Name: user_integrations user_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_integrations
    ADD CONSTRAINT user_integrations_pkey PRIMARY KEY (id);


--
-- Name: user_mutes user_mutes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_mutes
    ADD CONSTRAINT user_mutes_pkey PRIMARY KEY (id);


--
-- Name: user_post_timestamps user_post_timestamps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_post_timestamps
    ADD CONSTRAINT user_post_timestamps_pkey PRIMARY KEY (id);


--
-- Name: user_profiles user_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (id);


--
-- Name: user_timeouts user_timeouts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_timeouts
    ADD CONSTRAINT user_timeouts_pkey PRIMARY KEY (id);


--
-- Name: user_warnings user_warnings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_warnings
    ADD CONSTRAINT user_warnings_pkey PRIMARY KEY (id);


--
-- Name: username_history username_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.username_history
    ADD CONSTRAINT username_history_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: vpn_connection_logs vpn_connection_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vpn_connection_logs
    ADD CONSTRAINT vpn_connection_logs_pkey PRIMARY KEY (id);


--
-- Name: vpn_servers vpn_servers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vpn_servers
    ADD CONSTRAINT vpn_servers_pkey PRIMARY KEY (id);


--
-- Name: vpn_user_configs vpn_user_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vpn_user_configs
    ADD CONSTRAINT vpn_user_configs_pkey PRIMARY KEY (id);


--
-- Name: account_deletion_requests_requested_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX account_deletion_requests_requested_at_index ON public.account_deletion_requests USING btree (requested_at);


--
-- Name: account_deletion_requests_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX account_deletion_requests_status_index ON public.account_deletion_requests USING btree (status);


--
-- Name: account_deletion_requests_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX account_deletion_requests_user_id_index ON public.account_deletion_requests USING btree (user_id);


--
-- Name: activitypub_activities_activity_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX activitypub_activities_activity_id_index ON public.activitypub_activities USING btree (activity_id);


--
-- Name: activitypub_activities_activity_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_activities_activity_type_index ON public.activitypub_activities USING btree (activity_type);


--
-- Name: activitypub_activities_actor_uri_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_activities_actor_uri_index ON public.activitypub_activities USING btree (actor_uri);


--
-- Name: activitypub_activities_internal_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_activities_internal_message_id_index ON public.activitypub_activities USING btree (internal_message_id);


--
-- Name: activitypub_activities_internal_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_activities_internal_user_id_index ON public.activitypub_activities USING btree (internal_user_id);


--
-- Name: activitypub_activities_local_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_activities_local_index ON public.activitypub_activities USING btree (local);


--
-- Name: activitypub_activities_object_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_activities_object_id_index ON public.activitypub_activities USING btree (object_id);


--
-- Name: activitypub_activities_pending_remote_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_activities_pending_remote_inserted_idx ON public.activitypub_activities USING btree (inserted_at, id) WHERE ((processed = false) AND (local = false) AND (process_attempts < 2));


--
-- Name: activitypub_activities_process_attempts_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_activities_process_attempts_index ON public.activitypub_activities USING btree (process_attempts) WHERE ((processed = false) AND (process_attempts < 3));


--
-- Name: activitypub_activities_processed_local_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_activities_processed_local_index ON public.activitypub_activities USING btree (processed, local) WHERE ((processed = false) AND (local = false));


--
-- Name: activitypub_actors_actor_type_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_actors_actor_type_id_idx ON public.activitypub_actors USING btree (actor_type, id);


--
-- Name: activitypub_actors_community_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_actors_community_id_index ON public.activitypub_actors USING btree (community_id);


--
-- Name: activitypub_actors_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_actors_domain_index ON public.activitypub_actors USING btree (domain);


--
-- Name: activitypub_actors_uri_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX activitypub_actors_uri_index ON public.activitypub_actors USING btree (uri);


--
-- Name: activitypub_actors_username_domain_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX activitypub_actors_username_domain_unique_index ON public.activitypub_actors USING btree (username, domain);


--
-- Name: activitypub_actors_username_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_actors_username_index ON public.activitypub_actors USING btree (username);


--
-- Name: activitypub_deliveries_activity_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_deliveries_activity_id_index ON public.activitypub_deliveries USING btree (activity_id);


--
-- Name: activitypub_deliveries_next_retry_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_deliveries_next_retry_at_index ON public.activitypub_deliveries USING btree (next_retry_at);


--
-- Name: activitypub_deliveries_pending_retry_updated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_deliveries_pending_retry_updated_idx ON public.activitypub_deliveries USING btree (next_retry_at, updated_at, id) WHERE (((status)::text = 'pending'::text) AND (attempts < 10));


--
-- Name: activitypub_deliveries_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_deliveries_status_index ON public.activitypub_deliveries USING btree (status);


--
-- Name: activitypub_instances_blocked_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_instances_blocked_index ON public.activitypub_instances USING btree (blocked);


--
-- Name: activitypub_instances_domain_ci_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX activitypub_instances_domain_ci_unique ON public.activitypub_instances USING btree (lower((domain)::text));


--
-- Name: activitypub_instances_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX activitypub_instances_domain_index ON public.activitypub_instances USING btree (domain);


--
-- Name: activitypub_instances_federated_timeline_removal_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_instances_federated_timeline_removal_index ON public.activitypub_instances USING btree (federated_timeline_removal);


--
-- Name: activitypub_instances_silenced_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_instances_silenced_index ON public.activitypub_instances USING btree (silenced);


--
-- Name: activitypub_instances_unreachable_since_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_instances_unreachable_since_index ON public.activitypub_instances USING btree (unreachable_since) WHERE (unreachable_since IS NOT NULL);


--
-- Name: activitypub_relay_subscriptions_relay_uri_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX activitypub_relay_subscriptions_relay_uri_index ON public.activitypub_relay_subscriptions USING btree (relay_uri);


--
-- Name: activitypub_relay_subscriptions_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_relay_subscriptions_status_index ON public.activitypub_relay_subscriptions USING btree (status);


--
-- Name: activitypub_user_blocks_blocked_uri_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_user_blocks_blocked_uri_index ON public.activitypub_user_blocks USING btree (blocked_uri);


--
-- Name: activitypub_user_blocks_user_id_blocked_uri_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX activitypub_user_blocks_user_id_blocked_uri_index ON public.activitypub_user_blocks USING btree (user_id, blocked_uri);


--
-- Name: activitypub_user_blocks_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activitypub_user_blocks_user_id_index ON public.activitypub_user_blocks USING btree (user_id);


--
-- Name: announcement_dismissals_announcement_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcement_dismissals_announcement_id_index ON public.announcement_dismissals USING btree (announcement_id);


--
-- Name: announcement_dismissals_user_id_announcement_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX announcement_dismissals_user_id_announcement_id_index ON public.announcement_dismissals USING btree (user_id, announcement_id);


--
-- Name: announcement_dismissals_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcement_dismissals_user_id_index ON public.announcement_dismissals USING btree (user_id);


--
-- Name: announcements_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcements_active_index ON public.announcements USING btree (active);


--
-- Name: announcements_created_by_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcements_created_by_id_index ON public.announcements USING btree (created_by_id);


--
-- Name: announcements_ends_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcements_ends_at_index ON public.announcements USING btree (ends_at);


--
-- Name: announcements_starts_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcements_starts_at_index ON public.announcements USING btree (starts_at);


--
-- Name: announcements_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcements_type_index ON public.announcements USING btree (type);


--
-- Name: api_token_revocations_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_token_revocations_expires_at_index ON public.api_token_revocations USING btree (expires_at);


--
-- Name: api_token_revocations_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_token_revocations_token_hash_index ON public.api_token_revocations USING btree (token_hash);


--
-- Name: api_tokens_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_tokens_token_hash_index ON public.api_tokens USING btree (token_hash);


--
-- Name: api_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_tokens_user_id_index ON public.api_tokens USING btree (user_id);


--
-- Name: api_tokens_user_id_revoked_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_tokens_user_id_revoked_at_index ON public.api_tokens USING btree (user_id, revoked_at);


--
-- Name: app_passwords_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_passwords_expires_at_index ON public.app_passwords USING btree (expires_at);


--
-- Name: app_passwords_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX app_passwords_token_hash_index ON public.app_passwords USING btree (token_hash);


--
-- Name: app_passwords_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_passwords_user_id_index ON public.app_passwords USING btree (user_id);


--
-- Name: audit_logs_action_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_action_index ON public.audit_logs USING btree (action);


--
-- Name: audit_logs_admin_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_admin_id_index ON public.audit_logs USING btree (admin_id);


--
-- Name: audit_logs_admin_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_admin_id_inserted_at_index ON public.audit_logs USING btree (admin_id, inserted_at);


--
-- Name: audit_logs_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_inserted_at_index ON public.audit_logs USING btree (inserted_at);


--
-- Name: audit_logs_resource_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_resource_type_index ON public.audit_logs USING btree (resource_type);


--
-- Name: audit_logs_target_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_target_user_id_index ON public.audit_logs USING btree (target_user_id);


--
-- Name: auto_mod_rules_conversation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auto_mod_rules_conversation_id_index ON public.auto_mod_rules USING btree (conversation_id);


--
-- Name: auto_mod_rules_enabled_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auto_mod_rules_enabled_index ON public.auto_mod_rules USING btree (enabled);


--
-- Name: bluesky_inbound_events_related_post_uri_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bluesky_inbound_events_related_post_uri_index ON public.bluesky_inbound_events USING btree (related_post_uri);


--
-- Name: bluesky_inbound_events_user_id_event_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bluesky_inbound_events_user_id_event_id_index ON public.bluesky_inbound_events USING btree (user_id, event_id);


--
-- Name: bluesky_inbound_events_user_id_processed_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bluesky_inbound_events_user_id_processed_at_index ON public.bluesky_inbound_events USING btree (user_id, processed_at);


--
-- Name: calendar_events_calendar_id_dtstart_dtend_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_events_calendar_id_dtstart_dtend_index ON public.calendar_events USING btree (calendar_id, dtstart, dtend);


--
-- Name: calendar_events_calendar_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_events_calendar_id_index ON public.calendar_events USING btree (calendar_id);


--
-- Name: calendar_events_calendar_id_uid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX calendar_events_calendar_id_uid_index ON public.calendar_events USING btree (calendar_id, uid);


--
-- Name: calendar_events_dtend_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_events_dtend_index ON public.calendar_events USING btree (dtend);


--
-- Name: calendar_events_dtstart_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendar_events_dtstart_index ON public.calendar_events USING btree (dtstart);


--
-- Name: calendars_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calendars_user_id_index ON public.calendars USING btree (user_id);


--
-- Name: calendars_user_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX calendars_user_id_name_index ON public.calendars USING btree (user_id, name);


--
-- Name: calls_callee_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calls_callee_id_index ON public.calls USING btree (callee_id);


--
-- Name: calls_caller_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calls_caller_id_index ON public.calls USING btree (caller_id);


--
-- Name: calls_conversation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calls_conversation_id_index ON public.calls USING btree (conversation_id);


--
-- Name: calls_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calls_inserted_at_index ON public.calls USING btree (inserted_at);


--
-- Name: calls_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX calls_status_index ON public.calls USING btree (status);


--
-- Name: chat_conversation_members_conversation_id_left_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_conversation_members_conversation_id_left_at_index ON public.chat_conversation_members USING btree (conversation_id, left_at);


--
-- Name: chat_conversation_members_conversation_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_conversation_members_conversation_id_user_id_index ON public.chat_conversation_members USING btree (conversation_id, user_id);


--
-- Name: chat_conversation_members_last_read_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_conversation_members_last_read_message_id_index ON public.chat_conversation_members USING btree (last_read_message_id);


--
-- Name: chat_conversation_members_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_conversation_members_user_id_index ON public.chat_conversation_members USING btree (user_id);


--
-- Name: chat_conversations_creator_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_conversations_creator_id_index ON public.chat_conversations USING btree (creator_id);


--
-- Name: chat_conversations_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_conversations_hash_index ON public.chat_conversations USING btree (hash);


--
-- Name: chat_conversations_is_public_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_conversations_is_public_index ON public.chat_conversations USING btree (is_public);


--
-- Name: chat_conversations_last_message_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_conversations_last_message_at_index ON public.chat_conversations USING btree (last_message_at);


--
-- Name: chat_conversations_server_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_conversations_server_id_index ON public.chat_conversations USING btree (server_id);


--
-- Name: chat_conversations_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_conversations_type_index ON public.chat_conversations USING btree (type);


--
-- Name: chat_message_reactions_chat_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_message_reactions_chat_message_id_index ON public.chat_message_reactions USING btree (chat_message_id);


--
-- Name: chat_message_reactions_remote_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_message_reactions_remote_unique ON public.chat_message_reactions USING btree (chat_message_id, remote_actor_id, emoji) WHERE (remote_actor_id IS NOT NULL);


--
-- Name: chat_message_reactions_user_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_message_reactions_user_unique ON public.chat_message_reactions USING btree (chat_message_id, user_id, emoji) WHERE (user_id IS NOT NULL);


--
-- Name: chat_message_reads_chat_message_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_message_reads_chat_message_id_user_id_index ON public.chat_message_reads USING btree (chat_message_id, user_id);


--
-- Name: chat_message_reads_user_id_read_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_message_reads_user_id_read_at_index ON public.chat_message_reads USING btree (user_id, read_at);


--
-- Name: chat_messages_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_messages_active_idx ON public.chat_messages USING btree (conversation_id, inserted_at) WHERE (deleted_at IS NULL);


--
-- Name: chat_messages_conversation_federated_source_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_messages_conversation_federated_source_unique ON public.chat_messages USING btree (conversation_id, federated_source) WHERE (federated_source IS NOT NULL);


--
-- Name: chat_messages_conversation_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_messages_conversation_id_inserted_at_index ON public.chat_messages USING btree (conversation_id, inserted_at);


--
-- Name: chat_messages_link_preview_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_messages_link_preview_id_index ON public.chat_messages USING btree (link_preview_id);


--
-- Name: chat_messages_origin_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_messages_origin_domain_index ON public.chat_messages USING btree (origin_domain);


--
-- Name: chat_messages_reply_to_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_messages_reply_to_id_index ON public.chat_messages USING btree (reply_to_id);


--
-- Name: chat_messages_sender_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_messages_sender_id_index ON public.chat_messages USING btree (sender_id);


--
-- Name: chat_moderation_actions_conversation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_moderation_actions_conversation_id_index ON public.chat_moderation_actions USING btree (conversation_id);


--
-- Name: chat_moderation_actions_moderator_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_moderation_actions_moderator_id_index ON public.chat_moderation_actions USING btree (moderator_id);


--
-- Name: chat_moderation_actions_target_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_moderation_actions_target_user_id_index ON public.chat_moderation_actions USING btree (target_user_id);


--
-- Name: chat_user_hidden_messages_chat_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_user_hidden_messages_chat_message_id_index ON public.chat_user_hidden_messages USING btree (chat_message_id);


--
-- Name: chat_user_hidden_messages_user_id_hidden_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_user_hidden_messages_user_id_hidden_at_index ON public.chat_user_hidden_messages USING btree (user_id, hidden_at);


--
-- Name: chat_user_hidden_messages_user_message_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_user_hidden_messages_user_message_unique ON public.chat_user_hidden_messages USING btree (user_id, chat_message_id);


--
-- Name: chat_user_timeouts_user_conversation_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chat_user_timeouts_user_conversation_unique ON public.chat_user_timeouts USING btree (user_id, conversation_id);


--
-- Name: community_bans_conversation_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX community_bans_conversation_id_user_id_index ON public.community_bans USING btree (conversation_id, user_id);


--
-- Name: community_bans_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX community_bans_expires_at_index ON public.community_bans USING btree (expires_at);


--
-- Name: community_bans_origin_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX community_bans_origin_domain_index ON public.community_bans USING btree (origin_domain);


--
-- Name: community_bans_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX community_bans_user_id_index ON public.community_bans USING btree (user_id);


--
-- Name: community_flairs_community_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX community_flairs_community_id_index ON public.community_flairs USING btree (community_id);


--
-- Name: community_flairs_community_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX community_flairs_community_id_name_index ON public.community_flairs USING btree (community_id, name);


--
-- Name: contact_groups_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contact_groups_user_id_index ON public.contact_groups USING btree (user_id);


--
-- Name: contacts_group_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contacts_group_id_index ON public.contacts USING btree (group_id);


--
-- Name: contacts_pgp_fingerprint_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contacts_pgp_fingerprint_index ON public.contacts USING btree (pgp_fingerprint);


--
-- Name: contacts_uid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contacts_uid_index ON public.contacts USING btree (uid);


--
-- Name: contacts_user_id_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX contacts_user_id_email_index ON public.contacts USING btree (user_id, email);


--
-- Name: contacts_user_id_favorite_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contacts_user_id_favorite_index ON public.contacts USING btree (user_id, favorite);


--
-- Name: contacts_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contacts_user_id_index ON public.contacts USING btree (user_id);


--
-- Name: contacts_user_id_uid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX contacts_user_id_uid_index ON public.contacts USING btree (user_id, uid);


--
-- Name: conversation_members_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversation_members_active_index ON public.conversation_members USING btree (user_id, conversation_id) WHERE (left_at IS NULL);


--
-- Name: conversation_members_conversation_id_left_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversation_members_conversation_id_left_at_index ON public.conversation_members USING btree (conversation_id, left_at);


--
-- Name: conversation_members_conversation_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX conversation_members_conversation_id_user_id_index ON public.conversation_members USING btree (conversation_id, user_id);


--
-- Name: conversation_members_last_read_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversation_members_last_read_at_index ON public.conversation_members USING btree (last_read_at);


--
-- Name: conversation_members_last_read_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversation_members_last_read_message_id_index ON public.conversation_members USING btree (last_read_message_id);


--
-- Name: conversation_members_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversation_members_user_id_index ON public.conversation_members USING btree (user_id);


--
-- Name: conversations_channel_federated_source_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX conversations_channel_federated_source_unique ON public.conversations USING btree (federated_source) WHERE (((type)::text = 'channel'::text) AND (federated_source IS NOT NULL));


--
-- Name: conversations_community_category_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_community_category_index ON public.conversations USING btree (community_category);


--
-- Name: conversations_creator_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_creator_id_index ON public.conversations USING btree (creator_id);


--
-- Name: conversations_federated_source_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_federated_source_index ON public.conversations USING btree (federated_source);


--
-- Name: conversations_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX conversations_hash_index ON public.conversations USING btree (hash);


--
-- Name: conversations_is_federated_mirror_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_is_federated_mirror_index ON public.conversations USING btree (is_federated_mirror);


--
-- Name: conversations_is_public_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_is_public_index ON public.conversations USING btree (is_public);


--
-- Name: conversations_last_message_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_last_message_at_index ON public.conversations USING btree (last_message_at);


--
-- Name: conversations_remote_group_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_remote_group_actor_id_index ON public.conversations USING btree (remote_group_actor_id);


--
-- Name: conversations_server_id_channel_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_server_id_channel_position_index ON public.conversations USING btree (server_id, channel_position);


--
-- Name: conversations_server_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_server_id_index ON public.conversations USING btree (server_id);


--
-- Name: conversations_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversations_type_index ON public.conversations USING btree (type);


--
-- Name: creator_satisfaction_creator_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX creator_satisfaction_creator_id_index ON public.creator_satisfaction USING btree (creator_id);


--
-- Name: creator_satisfaction_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX creator_satisfaction_remote_actor_id_index ON public.creator_satisfaction USING btree (remote_actor_id);


--
-- Name: creator_satisfaction_user_id_creator_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX creator_satisfaction_user_id_creator_id_index ON public.creator_satisfaction USING btree (user_id, creator_id) WHERE ((creator_id IS NOT NULL) AND (remote_actor_id IS NULL));


--
-- Name: creator_satisfaction_user_id_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX creator_satisfaction_user_id_remote_actor_id_index ON public.creator_satisfaction USING btree (user_id, remote_actor_id) WHERE (remote_actor_id IS NOT NULL);


--
-- Name: custom_emojis_instance_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX custom_emojis_instance_domain_index ON public.custom_emojis USING btree (instance_domain);


--
-- Name: custom_emojis_shortcode_instance_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX custom_emojis_shortcode_instance_domain_index ON public.custom_emojis USING btree (shortcode, instance_domain);


--
-- Name: custom_emojis_visible_in_picker_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX custom_emojis_visible_in_picker_index ON public.custom_emojis USING btree (visible_in_picker);


--
-- Name: data_exports_download_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX data_exports_download_token_index ON public.data_exports USING btree (download_token);


--
-- Name: data_exports_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX data_exports_expires_at_index ON public.data_exports USING btree (expires_at);


--
-- Name: data_exports_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX data_exports_user_id_index ON public.data_exports USING btree (user_id);


--
-- Name: data_exports_user_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX data_exports_user_id_status_index ON public.data_exports USING btree (user_id, status);


--
-- Name: developer_webhook_deliveries_event_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX developer_webhook_deliveries_event_id_index ON public.developer_webhook_deliveries USING btree (event_id);


--
-- Name: developer_webhook_deliveries_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX developer_webhook_deliveries_inserted_at_index ON public.developer_webhook_deliveries USING btree (inserted_at);


--
-- Name: developer_webhook_deliveries_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX developer_webhook_deliveries_status_index ON public.developer_webhook_deliveries USING btree (status);


--
-- Name: developer_webhook_deliveries_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX developer_webhook_deliveries_user_id_index ON public.developer_webhook_deliveries USING btree (user_id);


--
-- Name: developer_webhook_deliveries_webhook_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX developer_webhook_deliveries_webhook_id_index ON public.developer_webhook_deliveries USING btree (webhook_id);


--
-- Name: developer_webhooks_user_id_enabled_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX developer_webhooks_user_id_enabled_index ON public.developer_webhooks USING btree (user_id, enabled);


--
-- Name: developer_webhooks_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX developer_webhooks_user_id_index ON public.developer_webhooks USING btree (user_id);


--
-- Name: device_tokens_enabled_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_tokens_enabled_index ON public.device_tokens USING btree (enabled);


--
-- Name: device_tokens_platform_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_tokens_platform_index ON public.device_tokens USING btree (platform);


--
-- Name: device_tokens_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX device_tokens_token_index ON public.device_tokens USING btree (token);


--
-- Name: device_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_tokens_user_id_index ON public.device_tokens USING btree (user_id);


--
-- Name: dns_query_stats_daily_rollup_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX dns_query_stats_daily_rollup_unique ON public.dns_query_stats USING btree (zone_id, query_date, qname, qtype, rcode, transport);


--
-- Name: dns_query_stats_zone_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dns_query_stats_zone_id_index ON public.dns_query_stats USING btree (zone_id);


--
-- Name: dns_query_stats_zone_id_query_date_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dns_query_stats_zone_id_query_date_index ON public.dns_query_stats USING btree (zone_id, query_date);


--
-- Name: dns_records_identity_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX dns_records_identity_unique ON public.dns_records USING btree (zone_id, name, type, content);


--
-- Name: dns_records_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dns_records_type_index ON public.dns_records USING btree (type);


--
-- Name: dns_records_zone_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dns_records_zone_id_index ON public.dns_records USING btree (zone_id);


--
-- Name: dns_records_zone_id_service_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dns_records_zone_id_service_index ON public.dns_records USING btree (zone_id, service);


--
-- Name: dns_records_zone_managed_key_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX dns_records_zone_managed_key_unique ON public.dns_records USING btree (zone_id, managed_key) WHERE (managed_key IS NOT NULL);


--
-- Name: dns_zone_service_configs_zone_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dns_zone_service_configs_zone_id_index ON public.dns_zone_service_configs USING btree (zone_id);


--
-- Name: dns_zone_service_configs_zone_service_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX dns_zone_service_configs_zone_service_unique ON public.dns_zone_service_configs USING btree (zone_id, service);


--
-- Name: dns_zones_domain_ci_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX dns_zones_domain_ci_unique ON public.dns_zones USING btree (lower((domain)::text));


--
-- Name: dns_zones_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dns_zones_status_index ON public.dns_zones USING btree (status);


--
-- Name: dns_zones_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dns_zones_user_id_index ON public.dns_zones USING btree (user_id);


--
-- Name: email_aliases_alias_email_ci_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_aliases_alias_email_ci_unique ON public.email_aliases USING btree (lower((alias_email)::text));


--
-- Name: email_aliases_alias_email_enabled_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_aliases_alias_email_enabled_index ON public.email_aliases USING btree (alias_email, enabled);


--
-- Name: email_aliases_alias_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_aliases_alias_email_index ON public.email_aliases USING btree (alias_email);


--
-- Name: email_aliases_alias_email_lower_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_aliases_alias_email_lower_idx ON public.email_aliases USING btree (lower((alias_email)::text));


--
-- Name: email_aliases_enabled_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_aliases_enabled_index ON public.email_aliases USING btree (enabled);


--
-- Name: email_aliases_target_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_aliases_target_email_index ON public.email_aliases USING btree (target_email);


--
-- Name: email_aliases_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_aliases_user_id_index ON public.email_aliases USING btree (user_id);


--
-- Name: email_auto_replies_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_auto_replies_user_id_index ON public.email_auto_replies USING btree (user_id);


--
-- Name: email_auto_reply_log_sender_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_auto_reply_log_sender_email_index ON public.email_auto_reply_log USING btree (sender_email);


--
-- Name: email_auto_reply_log_sent_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_auto_reply_log_sent_at_index ON public.email_auto_reply_log USING btree (sent_at);


--
-- Name: email_auto_reply_log_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_auto_reply_log_user_id_index ON public.email_auto_reply_log USING btree (user_id);


--
-- Name: email_auto_reply_log_user_id_sender_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_auto_reply_log_user_id_sender_email_index ON public.email_auto_reply_log USING btree (user_id, sender_email);


--
-- Name: email_blocked_senders_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_blocked_senders_domain_index ON public.email_blocked_senders USING btree (domain);


--
-- Name: email_blocked_senders_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_blocked_senders_email_index ON public.email_blocked_senders USING btree (email);


--
-- Name: email_blocked_senders_user_id_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_blocked_senders_user_id_domain_index ON public.email_blocked_senders USING btree (user_id, domain) WHERE (domain IS NOT NULL);


--
-- Name: email_blocked_senders_user_id_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_blocked_senders_user_id_email_index ON public.email_blocked_senders USING btree (user_id, email) WHERE (email IS NOT NULL);


--
-- Name: email_blocked_senders_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_blocked_senders_user_id_index ON public.email_blocked_senders USING btree (user_id);


--
-- Name: email_category_preferences_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_category_preferences_domain_index ON public.email_category_preferences USING btree (domain);


--
-- Name: email_category_preferences_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_category_preferences_email_index ON public.email_category_preferences USING btree (email);


--
-- Name: email_category_preferences_user_domain_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_category_preferences_user_domain_idx ON public.email_category_preferences USING btree (user_id, domain) WHERE (domain IS NOT NULL);


--
-- Name: email_category_preferences_user_email_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_category_preferences_user_email_idx ON public.email_category_preferences USING btree (user_id, email) WHERE (email IS NOT NULL);


--
-- Name: email_category_preferences_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_category_preferences_user_id_index ON public.email_category_preferences USING btree (user_id);


--
-- Name: email_custom_domains_domain_ci_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_custom_domains_domain_ci_unique ON public.email_custom_domains USING btree (lower((domain)::text));


--
-- Name: email_custom_domains_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_custom_domains_status_index ON public.email_custom_domains USING btree (status);


--
-- Name: email_custom_domains_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_custom_domains_user_id_index ON public.email_custom_domains USING btree (user_id);


--
-- Name: email_exports_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_exports_status_index ON public.email_exports USING btree (status);


--
-- Name: email_exports_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_exports_user_id_index ON public.email_exports USING btree (user_id);


--
-- Name: email_filters_enabled_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_filters_enabled_index ON public.email_filters USING btree (enabled);


--
-- Name: email_filters_priority_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_filters_priority_index ON public.email_filters USING btree (priority);


--
-- Name: email_filters_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_filters_user_id_index ON public.email_filters USING btree (user_id);


--
-- Name: email_folders_parent_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_folders_parent_id_index ON public.email_folders USING btree (parent_id);


--
-- Name: email_folders_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_folders_user_id_index ON public.email_folders USING btree (user_id);


--
-- Name: email_folders_user_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_folders_user_id_name_index ON public.email_folders USING btree (user_id, name);


--
-- Name: email_jobs_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_jobs_status_index ON public.email_jobs USING btree (status);


--
-- Name: email_jobs_status_scheduled_for_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_jobs_status_scheduled_for_index ON public.email_jobs USING btree (status, scheduled_for) WHERE ((status)::text = 'pending'::text);


--
-- Name: email_jobs_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_jobs_user_id_index ON public.email_jobs USING btree (user_id);


--
-- Name: email_labels_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_labels_user_id_index ON public.email_labels USING btree (user_id);


--
-- Name: email_labels_user_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_labels_user_id_name_index ON public.email_labels USING btree (user_id, name);


--
-- Name: email_message_labels_label_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_message_labels_label_id_index ON public.email_message_labels USING btree (label_id);


--
-- Name: email_message_labels_message_id_label_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_message_labels_message_id_label_id_index ON public.email_message_labels USING btree (message_id, label_id);


--
-- Name: email_messages_active_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_active_inserted_idx ON public.email_messages USING btree (inserted_at DESC) WHERE ((spam = false) AND (archived = false));


--
-- Name: email_messages_answered_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_answered_index ON public.email_messages USING btree (answered);


--
-- Name: email_messages_archived_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_archived_index ON public.email_messages USING btree (archived);


--
-- Name: email_messages_boomerang_performance_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_boomerang_performance_idx ON public.email_messages USING btree (mailbox_id, reply_later_at, spam, archived, deleted) WHERE ((reply_later_at IS NOT NULL) AND (NOT spam) AND (NOT archived) AND (NOT deleted));


--
-- Name: email_messages_category_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_category_index ON public.email_messages USING btree (category);


--
-- Name: email_messages_deleted_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_deleted_index ON public.email_messages USING btree (deleted);


--
-- Name: email_messages_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_expires_at_index ON public.email_messages USING btree (expires_at);


--
-- Name: email_messages_feed_performance_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_feed_performance_idx ON public.email_messages USING btree (mailbox_id, category, spam, archived, deleted, inserted_at) WHERE (((category)::text = 'feed'::text) AND (NOT spam) AND (NOT archived) AND (NOT deleted));


--
-- Name: email_messages_folder_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_folder_id_index ON public.email_messages USING btree (folder_id);


--
-- Name: email_messages_folder_mailbox_active_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_folder_mailbox_active_inserted_idx ON public.email_messages USING btree (folder_id, mailbox_id, inserted_at DESC) WHERE (deleted = false);


--
-- Name: email_messages_from_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_from_index ON public.email_messages USING btree ("from");


--
-- Name: email_messages_has_attachments_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_has_attachments_index ON public.email_messages USING btree (has_attachments);


--
-- Name: email_messages_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_messages_hash_index ON public.email_messages USING btree (hash);


--
-- Name: email_messages_imap_inbox_mailbox_id_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_imap_inbox_mailbox_id_id_idx ON public.email_messages USING btree (mailbox_id, id) WHERE ((reply_later_at IS NULL) AND (NOT spam) AND (NOT archived) AND (NOT deleted));


--
-- Name: email_messages_in_reply_to_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_in_reply_to_index ON public.email_messages USING btree (in_reply_to);


--
-- Name: email_messages_inbox_performance_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_inbox_performance_idx ON public.email_messages USING btree (mailbox_id, category, spam, archived, deleted, reply_later_at, inserted_at) WHERE ((NOT spam) AND (NOT archived) AND (NOT deleted) AND ((category)::text <> ALL ((ARRAY['feed'::character varying, 'ledger'::character varying, 'stack'::character varying])::text[])) AND (reply_later_at IS NULL));


--
-- Name: email_messages_inbox_unread_folderless_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_inbox_unread_folderless_inserted_idx ON public.email_messages USING btree (mailbox_id, inserted_at DESC) WHERE ((read = false) AND (spam = false) AND (archived = false) AND (deleted = false) AND (reply_later_at IS NULL) AND (folder_id IS NULL) AND ((category IS NULL) OR ((category)::text <> ALL ((ARRAY['feed'::character varying, 'ledger'::character varying, 'stack'::character varying])::text[]))));


--
-- Name: email_messages_is_newsletter_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_is_newsletter_index ON public.email_messages USING btree (is_newsletter);


--
-- Name: email_messages_is_notification_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_is_notification_index ON public.email_messages USING btree (is_notification);


--
-- Name: email_messages_is_receipt_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_is_receipt_index ON public.email_messages USING btree (is_receipt);


--
-- Name: email_messages_jmap_blob_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_jmap_blob_id_index ON public.email_messages USING btree (jmap_blob_id);


--
-- Name: email_messages_ledger_performance_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_ledger_performance_idx ON public.email_messages USING btree (mailbox_id, category, spam, archived, deleted, inserted_at) WHERE (((category)::text = 'ledger'::text) AND (NOT spam) AND (NOT archived) AND (NOT deleted));


--
-- Name: email_messages_mailbox_active_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_mailbox_active_inserted_idx ON public.email_messages USING btree (mailbox_id, inserted_at DESC) WHERE ((spam = false) AND (archived = false) AND (deleted = false));


--
-- Name: email_messages_mailbox_id_deleted_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_mailbox_id_deleted_index ON public.email_messages USING btree (mailbox_id, deleted);


--
-- Name: email_messages_mailbox_id_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_mailbox_id_id_idx ON public.email_messages USING btree (mailbox_id, id);


--
-- Name: email_messages_mailbox_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_mailbox_id_index ON public.email_messages USING btree (mailbox_id);


--
-- Name: email_messages_message_id_mailbox_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_messages_message_id_mailbox_id_index ON public.email_messages USING btree (message_id, mailbox_id);


--
-- Name: email_messages_priority_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_priority_index ON public.email_messages USING btree (priority);


--
-- Name: email_messages_read_performance_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_read_performance_idx ON public.email_messages USING btree (mailbox_id, read, spam, archived, deleted, inserted_at) WHERE (read AND (NOT spam) AND (NOT archived) AND (NOT deleted));


--
-- Name: email_messages_reply_later_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_reply_later_at_index ON public.email_messages USING btree (reply_later_at);


--
-- Name: email_messages_scheduled_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_scheduled_at_index ON public.email_messages USING btree (scheduled_at);


--
-- Name: email_messages_search_index_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_search_index_index ON public.email_messages USING gin (search_index);


--
-- Name: email_messages_spam_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_spam_index ON public.email_messages USING btree (spam);


--
-- Name: email_messages_stack_performance_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_stack_performance_idx ON public.email_messages USING btree (mailbox_id, category, stack_at, spam, archived, deleted) WHERE (((category)::text = 'stack'::text) AND (stack_at IS NOT NULL) AND (NOT spam) AND (NOT archived) AND (NOT deleted));


--
-- Name: email_messages_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_status_index ON public.email_messages USING btree (status);


--
-- Name: email_messages_status_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_status_inserted_at_idx ON public.email_messages USING btree (status, inserted_at DESC);


--
-- Name: email_messages_thread_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_thread_id_index ON public.email_messages USING btree (thread_id);


--
-- Name: email_messages_to_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_to_index ON public.email_messages USING btree ("to");


--
-- Name: email_messages_unread_performance_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_messages_unread_performance_idx ON public.email_messages USING btree (mailbox_id, read, spam, archived, deleted, inserted_at) WHERE ((NOT read) AND (NOT spam) AND (NOT archived) AND (NOT deleted));


--
-- Name: email_safe_senders_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_safe_senders_domain_index ON public.email_safe_senders USING btree (domain);


--
-- Name: email_safe_senders_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_safe_senders_email_index ON public.email_safe_senders USING btree (email);


--
-- Name: email_safe_senders_user_id_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_safe_senders_user_id_domain_index ON public.email_safe_senders USING btree (user_id, domain) WHERE (domain IS NOT NULL);


--
-- Name: email_safe_senders_user_id_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_safe_senders_user_id_email_index ON public.email_safe_senders USING btree (user_id, email) WHERE (email IS NOT NULL);


--
-- Name: email_safe_senders_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_safe_senders_user_id_index ON public.email_safe_senders USING btree (user_id);


--
-- Name: email_submissions_email_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_submissions_email_id_index ON public.email_submissions USING btree (email_id);


--
-- Name: email_submissions_mailbox_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_submissions_mailbox_id_index ON public.email_submissions USING btree (mailbox_id);


--
-- Name: email_suppressions_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_suppressions_email_index ON public.email_suppressions USING btree (email);


--
-- Name: email_suppressions_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_suppressions_expires_at_index ON public.email_suppressions USING btree (expires_at);


--
-- Name: email_suppressions_user_id_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_suppressions_user_id_email_index ON public.email_suppressions USING btree (user_id, email);


--
-- Name: email_suppressions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_suppressions_user_id_index ON public.email_suppressions USING btree (user_id);


--
-- Name: email_templates_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_templates_user_id_index ON public.email_templates USING btree (user_id);


--
-- Name: email_templates_user_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_templates_user_id_name_index ON public.email_templates USING btree (user_id, name);


--
-- Name: email_threads_mailbox_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_threads_mailbox_id_index ON public.email_threads USING btree (mailbox_id);


--
-- Name: email_threads_mailbox_id_subject_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_threads_mailbox_id_subject_hash_index ON public.email_threads USING btree (mailbox_id, subject_hash);


--
-- Name: email_unsubscribes_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_unsubscribes_email_index ON public.email_unsubscribes USING btree (email);


--
-- Name: email_unsubscribes_email_list_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_unsubscribes_email_list_id_index ON public.email_unsubscribes USING btree (email, list_id);


--
-- Name: email_unsubscribes_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_unsubscribes_token_index ON public.email_unsubscribes USING btree (token);


--
-- Name: email_unsubscribes_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_unsubscribes_user_id_index ON public.email_unsubscribes USING btree (user_id);


--
-- Name: federated_boosts_activitypub_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX federated_boosts_activitypub_id_index ON public.federated_boosts USING btree (activitypub_id);


--
-- Name: federated_boosts_message_id_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX federated_boosts_message_id_remote_actor_id_index ON public.federated_boosts USING btree (message_id, remote_actor_id);


--
-- Name: federated_boosts_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX federated_boosts_remote_actor_id_index ON public.federated_boosts USING btree (remote_actor_id);


--
-- Name: federated_dislikes_activitypub_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX federated_dislikes_activitypub_id_index ON public.federated_dislikes USING btree (activitypub_id);


--
-- Name: federated_dislikes_message_id_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX federated_dislikes_message_id_remote_actor_id_index ON public.federated_dislikes USING btree (message_id, remote_actor_id);


--
-- Name: federated_dislikes_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX federated_dislikes_remote_actor_id_index ON public.federated_dislikes USING btree (remote_actor_id);


--
-- Name: federated_likes_activitypub_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX federated_likes_activitypub_id_index ON public.federated_likes USING btree (activitypub_id);


--
-- Name: federated_likes_message_id_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX federated_likes_message_id_remote_actor_id_index ON public.federated_likes USING btree (message_id, remote_actor_id);


--
-- Name: federated_likes_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX federated_likes_remote_actor_id_index ON public.federated_likes USING btree (remote_actor_id);


--
-- Name: federated_quotes_activitypub_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX federated_quotes_activitypub_id_index ON public.federated_quotes USING btree (activitypub_id);


--
-- Name: federated_quotes_message_id_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX federated_quotes_message_id_remote_actor_id_index ON public.federated_quotes USING btree (message_id, remote_actor_id);


--
-- Name: federated_quotes_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX federated_quotes_remote_actor_id_index ON public.federated_quotes USING btree (remote_actor_id);


--
-- Name: file_shares_access_level_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX file_shares_access_level_index ON public.file_shares USING btree (access_level);


--
-- Name: file_shares_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX file_shares_expires_at_index ON public.file_shares USING btree (expires_at);


--
-- Name: file_shares_stored_file_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX file_shares_stored_file_id_index ON public.file_shares USING btree (stored_file_id);


--
-- Name: file_shares_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX file_shares_token_index ON public.file_shares USING btree (token);


--
-- Name: file_shares_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX file_shares_user_id_index ON public.file_shares USING btree (user_id);


--
-- Name: follows_followed_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX follows_followed_id_index ON public.follows USING btree (followed_id);


--
-- Name: follows_follower_id_followed_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX follows_follower_id_followed_id_index ON public.follows USING btree (follower_id, followed_id);


--
-- Name: follows_follower_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX follows_follower_id_index ON public.follows USING btree (follower_id);


--
-- Name: follows_follower_id_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX follows_follower_id_remote_actor_id_index ON public.follows USING btree (follower_id, remote_actor_id);


--
-- Name: follows_pending_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX follows_pending_index ON public.follows USING btree (pending);


--
-- Name: follows_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX follows_remote_actor_id_index ON public.follows USING btree (remote_actor_id);


--
-- Name: forwarded_messages_alias_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX forwarded_messages_alias_id_index ON public.forwarded_messages USING btree (alias_id);


--
-- Name: forwarded_messages_final_recipient_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX forwarded_messages_final_recipient_index ON public.forwarded_messages USING btree (final_recipient);


--
-- Name: forwarded_messages_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX forwarded_messages_inserted_at_index ON public.forwarded_messages USING btree (inserted_at);


--
-- Name: forwarded_messages_original_recipient_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX forwarded_messages_original_recipient_index ON public.forwarded_messages USING btree (original_recipient);


--
-- Name: friend_requests_recipient_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX friend_requests_recipient_id_index ON public.friend_requests USING btree (recipient_id);


--
-- Name: friend_requests_requester_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX friend_requests_requester_id_index ON public.friend_requests USING btree (requester_id);


--
-- Name: friend_requests_requester_id_recipient_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX friend_requests_requester_id_recipient_id_index ON public.friend_requests USING btree (requester_id, recipient_id);


--
-- Name: friend_requests_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX friend_requests_status_index ON public.friend_requests USING btree (status);


--
-- Name: group_follows_activitypub_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX group_follows_activitypub_id_index ON public.group_follows USING btree (activitypub_id);


--
-- Name: group_follows_group_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX group_follows_group_actor_id_index ON public.group_follows USING btree (group_actor_id);


--
-- Name: group_follows_remote_actor_id_group_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX group_follows_remote_actor_id_group_actor_id_index ON public.group_follows USING btree (remote_actor_id, group_actor_id);


--
-- Name: handle_history_handle_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX handle_history_handle_index ON public.handle_history USING btree (handle);


--
-- Name: handle_history_reserved_until_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX handle_history_reserved_until_index ON public.handle_history USING btree (reserved_until);


--
-- Name: handle_history_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX handle_history_user_id_index ON public.handle_history USING btree (user_id);


--
-- Name: hashtag_follows_hashtag_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hashtag_follows_hashtag_id_index ON public.hashtag_follows USING btree (hashtag_id);


--
-- Name: hashtag_follows_user_id_hashtag_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hashtag_follows_user_id_hashtag_id_index ON public.hashtag_follows USING btree (user_id, hashtag_id);


--
-- Name: hashtags_last_used_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hashtags_last_used_at_index ON public.hashtags USING btree (last_used_at);


--
-- Name: hashtags_normalized_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hashtags_normalized_name_idx ON public.hashtags USING btree (normalized_name);


--
-- Name: hashtags_normalized_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX hashtags_normalized_name_index ON public.hashtags USING btree (normalized_name);


--
-- Name: hashtags_use_count_desc_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hashtags_use_count_desc_index ON public.hashtags USING btree (use_count DESC);


--
-- Name: hashtags_use_count_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hashtags_use_count_index ON public.hashtags USING btree (use_count);


--
-- Name: imap_subscriptions_user_id_folder_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX imap_subscriptions_user_id_folder_name_index ON public.imap_subscriptions USING btree (user_id, folder_name);


--
-- Name: imap_subscriptions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX imap_subscriptions_user_id_index ON public.imap_subscriptions USING btree (user_id);


--
-- Name: invite_code_uses_invite_code_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invite_code_uses_invite_code_id_index ON public.invite_code_uses USING btree (invite_code_id);


--
-- Name: invite_code_uses_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invite_code_uses_user_id_index ON public.invite_code_uses USING btree (user_id);


--
-- Name: invite_code_uses_user_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX invite_code_uses_user_id_unique ON public.invite_code_uses USING btree (user_id);


--
-- Name: invite_codes_code_upper_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX invite_codes_code_upper_unique ON public.invite_codes USING btree (upper((code)::text));


--
-- Name: invite_codes_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invite_codes_expires_at_index ON public.invite_codes USING btree (expires_at);


--
-- Name: invite_codes_is_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invite_codes_is_active_index ON public.invite_codes USING btree (is_active);


--
-- Name: jmap_email_changes_mailbox_id_email_id_state_counter_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jmap_email_changes_mailbox_id_email_id_state_counter_index ON public.jmap_email_changes USING btree (mailbox_id, email_id, state_counter);


--
-- Name: jmap_email_changes_mailbox_id_state_counter_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jmap_email_changes_mailbox_id_state_counter_index ON public.jmap_email_changes USING btree (mailbox_id, state_counter);


--
-- Name: jmap_email_tombstones_mailbox_id_email_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jmap_email_tombstones_mailbox_id_email_id_index ON public.jmap_email_tombstones USING btree (mailbox_id, email_id);


--
-- Name: jmap_email_tombstones_mailbox_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jmap_email_tombstones_mailbox_id_inserted_at_index ON public.jmap_email_tombstones USING btree (mailbox_id, inserted_at);


--
-- Name: jmap_state_tracking_mailbox_id_entity_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX jmap_state_tracking_mailbox_id_entity_type_index ON public.jmap_state_tracking USING btree (mailbox_id, entity_type);


--
-- Name: lemmy_counts_cache_activitypub_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX lemmy_counts_cache_activitypub_id_index ON public.lemmy_counts_cache USING btree (activitypub_id);


--
-- Name: lemmy_counts_cache_fetched_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lemmy_counts_cache_fetched_at_index ON public.lemmy_counts_cache USING btree (fetched_at);


--
-- Name: link_preview_jobs_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX link_preview_jobs_message_id_index ON public.link_preview_jobs USING btree (message_id);


--
-- Name: link_preview_jobs_status_attempts_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX link_preview_jobs_status_attempts_index ON public.link_preview_jobs USING btree (status, attempts) WHERE (((status)::text = 'pending'::text) AND (attempts < 3));


--
-- Name: link_preview_jobs_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX link_preview_jobs_status_index ON public.link_preview_jobs USING btree (status);


--
-- Name: link_preview_jobs_url_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX link_preview_jobs_url_index ON public.link_preview_jobs USING btree (url);


--
-- Name: link_previews_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX link_previews_status_index ON public.link_previews USING btree (status);


--
-- Name: link_previews_url_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX link_previews_url_index ON public.link_previews USING btree (url);


--
-- Name: list_members_list_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX list_members_list_id_index ON public.list_members USING btree (list_id);


--
-- Name: list_members_list_id_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX list_members_list_id_remote_actor_id_index ON public.list_members USING btree (list_id, remote_actor_id) WHERE (remote_actor_id IS NOT NULL);


--
-- Name: list_members_list_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX list_members_list_id_user_id_index ON public.list_members USING btree (list_id, user_id) WHERE (user_id IS NOT NULL);


--
-- Name: list_members_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX list_members_remote_actor_id_index ON public.list_members USING btree (remote_actor_id);


--
-- Name: list_members_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX list_members_user_id_index ON public.list_members USING btree (user_id);


--
-- Name: lists_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lists_user_id_index ON public.lists USING btree (user_id);


--
-- Name: lists_user_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX lists_user_id_name_index ON public.lists USING btree (user_id, name);


--
-- Name: mailboxes_email_ci_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX mailboxes_email_ci_unique ON public.mailboxes USING btree (lower((email)::text));


--
-- Name: mailboxes_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX mailboxes_email_index ON public.mailboxes USING btree (email);


--
-- Name: mailboxes_forward_enabled_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mailboxes_forward_enabled_index ON public.mailboxes USING btree (forward_enabled);


--
-- Name: mailboxes_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mailboxes_user_id_index ON public.mailboxes USING btree (user_id);


--
-- Name: mailboxes_username_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mailboxes_username_index ON public.mailboxes USING btree (username);


--
-- Name: message_reactions_federated_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_reactions_federated_index ON public.message_reactions USING btree (federated);


--
-- Name: message_reactions_federated_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX message_reactions_federated_unique_index ON public.message_reactions USING btree (message_id, remote_actor_id, emoji) WHERE (remote_actor_id IS NOT NULL);


--
-- Name: message_reactions_message_id_emoji_emoji_url_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_reactions_message_id_emoji_emoji_url_index ON public.message_reactions USING btree (message_id, emoji, emoji_url);


--
-- Name: message_reactions_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_reactions_message_id_index ON public.message_reactions USING btree (message_id);


--
-- Name: message_reactions_message_id_user_id_emoji_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX message_reactions_message_id_user_id_emoji_index ON public.message_reactions USING btree (message_id, user_id, emoji);


--
-- Name: message_reactions_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_reactions_remote_actor_id_index ON public.message_reactions USING btree (remote_actor_id);


--
-- Name: message_votes_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_votes_inserted_at_index ON public.message_votes USING btree (inserted_at);


--
-- Name: message_votes_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_votes_message_id_index ON public.message_votes USING btree (message_id);


--
-- Name: message_votes_message_id_vote_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_votes_message_id_vote_type_index ON public.message_votes USING btree (message_id, vote_type);


--
-- Name: message_votes_message_id_vote_type_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_votes_message_id_vote_type_inserted_at_index ON public.message_votes USING btree (message_id, vote_type, inserted_at);


--
-- Name: message_votes_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_votes_user_id_index ON public.message_votes USING btree (user_id);


--
-- Name: message_votes_user_id_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX message_votes_user_id_message_id_index ON public.message_votes USING btree (user_id, message_id);


--
-- Name: message_votes_vote_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_votes_vote_type_index ON public.message_votes USING btree (vote_type);


--
-- Name: messages_activitypub_id_canonical_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_activitypub_id_canonical_idx ON public.messages USING btree (activitypub_id_canonical) WHERE (activitypub_id_canonical IS NOT NULL);


--
-- Name: messages_activitypub_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messages_activitypub_id_index ON public.messages USING btree (activitypub_id) WHERE (activitypub_id IS NOT NULL);


--
-- Name: messages_activitypub_url_canonical_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_activitypub_url_canonical_idx ON public.messages USING btree (activitypub_url_canonical) WHERE (activitypub_url_canonical IS NOT NULL);


--
-- Name: messages_activitypub_url_not_null_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_activitypub_url_not_null_idx ON public.messages USING btree (activitypub_url) WHERE (activitypub_url IS NOT NULL);


--
-- Name: messages_approval_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_approval_status_index ON public.messages USING btree (approval_status);


--
-- Name: messages_approval_visibility_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_approval_visibility_inserted_idx ON public.messages USING btree (approval_status, visibility, inserted_at);


--
-- Name: messages_bluesky_cid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_bluesky_cid_index ON public.messages USING btree (bluesky_cid);


--
-- Name: messages_bluesky_uri_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messages_bluesky_uri_index ON public.messages USING btree (bluesky_uri) WHERE (bluesky_uri IS NOT NULL);


--
-- Name: messages_category_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_category_index ON public.messages USING btree (category) WHERE (category IS NOT NULL);


--
-- Name: messages_community_actor_uri_fed_public_top_level_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_community_actor_uri_fed_public_top_level_inserted_idx ON public.messages USING btree (((media_metadata ->> 'community_actor_uri'::text)), inserted_at DESC) WHERE ((federated = true) AND ((visibility)::text = 'public'::text) AND (deleted_at IS NULL) AND (reply_to_id IS NULL) AND ((media_metadata ->> 'community_actor_uri'::text) IS NOT NULL));


--
-- Name: messages_community_actor_uri_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_community_actor_uri_idx ON public.messages USING btree (((media_metadata ->> 'community_actor_uri'::text))) WHERE ((media_metadata ->> 'community_actor_uri'::text) IS NOT NULL);


--
-- Name: messages_conv_visibility_deleted_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_conv_visibility_deleted_inserted_idx ON public.messages USING btree (conversation_id, visibility, deleted_at, inserted_at);


--
-- Name: messages_conversation_id_deleted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_conversation_id_deleted_at_index ON public.messages USING btree (conversation_id, deleted_at);


--
-- Name: messages_conversation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_conversation_id_index ON public.messages USING btree (conversation_id);


--
-- Name: messages_conversation_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_conversation_id_inserted_at_index ON public.messages USING btree (conversation_id, inserted_at);


--
-- Name: messages_conversation_id_is_pinned_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_conversation_id_is_pinned_index ON public.messages USING btree (conversation_id, is_pinned);


--
-- Name: messages_conversation_timeline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_conversation_timeline_idx ON public.messages USING btree (conversation_id, inserted_at, deleted_at) WHERE (deleted_at IS NULL);


--
-- Name: messages_extracted_hashtags_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_extracted_hashtags_index ON public.messages USING btree (extracted_hashtags);


--
-- Name: messages_federated_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_federated_index ON public.messages USING btree (federated);


--
-- Name: messages_flair_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_flair_id_index ON public.messages USING btree (flair_id);


--
-- Name: messages_inserted_at_desc_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_inserted_at_desc_index ON public.messages USING btree (inserted_at DESC);


--
-- Name: messages_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_inserted_at_index ON public.messages USING btree (inserted_at);


--
-- Name: messages_like_count_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_like_count_index ON public.messages USING btree (like_count);


--
-- Name: messages_link_preview_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_link_preview_id_index ON public.messages USING btree (link_preview_id);


--
-- Name: messages_locked_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_locked_at_index ON public.messages USING btree (locked_at);


--
-- Name: messages_locked_by_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_locked_by_id_index ON public.messages USING btree (locked_by_id);


--
-- Name: messages_media_metadata_gin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_media_metadata_gin_idx ON public.messages USING gin (media_metadata jsonb_path_ops);


--
-- Name: messages_original_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_original_message_id_index ON public.messages USING btree (original_message_id);


--
-- Name: messages_post_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_post_type_index ON public.messages USING btree (post_type);


--
-- Name: messages_post_type_visibility_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_post_type_visibility_active_index ON public.messages USING btree (post_type, visibility) WHERE (deleted_at IS NULL);


--
-- Name: messages_primary_url_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_primary_url_index ON public.messages USING btree (primary_url);


--
-- Name: messages_promoted_from_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_promoted_from_index ON public.messages USING btree (promoted_from);


--
-- Name: messages_quoted_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_quoted_message_id_index ON public.messages USING btree (quoted_message_id);


--
-- Name: messages_remote_actor_fed_public_top_level_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_remote_actor_fed_public_top_level_inserted_idx ON public.messages USING btree (remote_actor_id, inserted_at DESC) WHERE ((federated = true) AND ((visibility)::text = 'public'::text) AND (deleted_at IS NULL) AND (reply_to_id IS NULL) AND (remote_actor_id IS NOT NULL));


--
-- Name: messages_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_remote_actor_id_index ON public.messages USING btree (remote_actor_id);


--
-- Name: messages_remote_actor_visibility_deleted_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_remote_actor_visibility_deleted_inserted_idx ON public.messages USING btree (remote_actor_id, visibility, deleted_at, inserted_at) WHERE (remote_actor_id IS NOT NULL);


--
-- Name: messages_reply_to_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_reply_to_id_index ON public.messages USING btree (reply_to_id);


--
-- Name: messages_reply_to_id_inserted_at_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_reply_to_id_inserted_at_id_idx ON public.messages USING btree (reply_to_id, inserted_at, id) WHERE (reply_to_id IS NOT NULL);


--
-- Name: messages_score_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_score_index ON public.messages USING btree (score);


--
-- Name: messages_search_index_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_search_index_index ON public.messages USING gin (search_index);


--
-- Name: messages_sender_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_sender_id_index ON public.messages USING btree (sender_id);


--
-- Name: messages_sender_id_is_draft_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_sender_id_is_draft_index ON public.messages USING btree (sender_id, is_draft) WHERE (is_draft = true);


--
-- Name: messages_sender_visibility_deleted_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_sender_visibility_deleted_inserted_idx ON public.messages USING btree (sender_id, visibility, deleted_at, inserted_at);


--
-- Name: messages_sensitive_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_sensitive_index ON public.messages USING btree (sensitive);


--
-- Name: messages_shared_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_shared_message_id_index ON public.messages USING btree (shared_message_id);


--
-- Name: messages_title_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_title_index ON public.messages USING btree (title);


--
-- Name: messages_upvotes_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_upvotes_index ON public.messages USING btree (upvotes);


--
-- Name: messages_user_timeline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_user_timeline_idx ON public.messages USING btree (sender_id, post_type, visibility, deleted_at, inserted_at) WHERE (((post_type)::text = 'post'::text) AND (deleted_at IS NULL));


--
-- Name: messages_visibility_deleted_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_visibility_deleted_inserted_idx ON public.messages USING btree (visibility, deleted_at, inserted_at);


--
-- Name: messages_visibility_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_visibility_index ON public.messages USING btree (visibility);


--
-- Name: messaging_federation_account_presence_states_expires_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_account_presence_states_expires_at_idx ON public.messaging_federation_account_presence_states USING btree (expires_at_remote);


--
-- Name: messaging_federation_account_presence_states_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_account_presence_states_unique ON public.messaging_federation_account_presence_states USING btree (remote_actor_id);


--
-- Name: messaging_federation_account_presence_states_updated_at_remote_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_account_presence_states_updated_at_remote_ ON public.messaging_federation_account_presence_states USING btree (updated_at_remote);


--
-- Name: messaging_federation_call_sessions_conversation_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_call_sessions_conversation_inserted_at_idx ON public.messaging_federation_call_sessions USING btree (conversation_id, inserted_at);


--
-- Name: messaging_federation_call_sessions_remote_domain_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_call_sessions_remote_domain_status_idx ON public.messaging_federation_call_sessions USING btree (remote_domain, status);


--
-- Name: messaging_federation_call_sessions_user_call_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_call_sessions_user_call_unique ON public.messaging_federation_call_sessions USING btree (local_user_id, federated_call_id);


--
-- Name: messaging_federation_discovered_peers_domain_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_discovered_peers_domain_unique ON public.messaging_federation_discovered_peers USING btree (domain);


--
-- Name: messaging_federation_events_archive_origin_event_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_events_archive_origin_event_id_unique ON public.messaging_federation_events_archive USING btree (origin_domain, event_id);


--
-- Name: messaging_federation_events_archive_origin_idempotency_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_events_archive_origin_idempotency_idx ON public.messaging_federation_events_archive USING btree (origin_domain, idempotency_key);


--
-- Name: messaging_federation_events_archive_partition_month_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_events_archive_partition_month_idx ON public.messaging_federation_events_archive USING btree (partition_month);


--
-- Name: messaging_federation_events_archive_stream_seq_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_events_archive_stream_seq_idx ON public.messaging_federation_events_archive USING btree (origin_domain, stream_id, sequence);


--
-- Name: messaging_federation_events_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_events_inserted_at_index ON public.messaging_federation_events USING btree (inserted_at);


--
-- Name: messaging_federation_events_origin_domain_stream_id_sequence_in; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_events_origin_domain_stream_id_sequence_in ON public.messaging_federation_events USING btree (origin_domain, stream_id, sequence);


--
-- Name: messaging_federation_events_origin_event_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_events_origin_event_id_unique ON public.messaging_federation_events USING btree (origin_domain, event_id);


--
-- Name: messaging_federation_events_origin_idempotency_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_events_origin_idempotency_unique ON public.messaging_federation_events USING btree (origin_domain, idempotency_key);


--
-- Name: messaging_federation_extension_events_conversation_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_extension_events_conversation_type_idx ON public.messaging_federation_extension_events USING btree (conversation_id, event_type);


--
-- Name: messaging_federation_extension_events_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_extension_events_occurred_at_idx ON public.messaging_federation_extension_events USING btree (occurred_at);


--
-- Name: messaging_federation_extension_events_server_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_extension_events_server_type_idx ON public.messaging_federation_extension_events USING btree (server_id, event_type);


--
-- Name: messaging_federation_extension_events_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_extension_events_unique ON public.messaging_federation_extension_events USING btree (event_type, origin_domain, event_key);


--
-- Name: messaging_federation_invite_states_origin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_invite_states_origin_idx ON public.messaging_federation_invite_states USING btree (origin_domain);


--
-- Name: messaging_federation_invite_states_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_invite_states_unique ON public.messaging_federation_invite_states USING btree (conversation_id, target_uri);


--
-- Name: messaging_federation_membership_states_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_membership_states_actor_idx ON public.messaging_federation_membership_states USING btree (remote_actor_id);


--
-- Name: messaging_federation_membership_states_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_membership_states_unique ON public.messaging_federation_membership_states USING btree (conversation_id, remote_actor_id);


--
-- Name: messaging_federation_outbox_event_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_outbox_event_id_unique ON public.messaging_federation_outbox_events USING btree (event_id);


--
-- Name: messaging_federation_outbox_partition_month_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_outbox_partition_month_idx ON public.messaging_federation_outbox_events USING btree (partition_month);


--
-- Name: messaging_federation_outbox_status_retry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_outbox_status_retry_idx ON public.messaging_federation_outbox_events USING btree (status, next_retry_at);


--
-- Name: messaging_federation_peer_policies_blocked_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_peer_policies_blocked_index ON public.messaging_federation_peer_policies USING btree (blocked);


--
-- Name: messaging_federation_peer_policies_domain_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_peer_policies_domain_unique ON public.messaging_federation_peer_policies USING btree (domain);


--
-- Name: messaging_federation_peer_policies_updated_by_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_peer_policies_updated_by_id_index ON public.messaging_federation_peer_policies USING btree (updated_by_id);


--
-- Name: messaging_federation_presence_states_expires_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_presence_states_expires_at_idx ON public.messaging_federation_presence_states USING btree (expires_at_remote);


--
-- Name: messaging_federation_presence_states_server_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_presence_states_server_status_idx ON public.messaging_federation_presence_states USING btree (server_id, status);


--
-- Name: messaging_federation_presence_states_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_presence_states_unique ON public.messaging_federation_presence_states USING btree (server_id, remote_actor_id);


--
-- Name: messaging_federation_presence_states_updated_at_remote_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_presence_states_updated_at_remote_idx ON public.messaging_federation_presence_states USING btree (updated_at_remote);


--
-- Name: messaging_federation_read_cursors_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_read_cursors_actor_idx ON public.messaging_federation_read_cursors USING btree (remote_actor_id);


--
-- Name: messaging_federation_read_cursors_conversation_message_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_read_cursors_conversation_message_idx ON public.messaging_federation_read_cursors USING btree (conversation_id, chat_message_id);


--
-- Name: messaging_federation_read_cursors_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_read_cursors_unique ON public.messaging_federation_read_cursors USING btree (conversation_id, remote_actor_id);


--
-- Name: messaging_federation_read_receipts_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_read_receipts_actor_idx ON public.messaging_federation_read_receipts USING btree (remote_actor_id);


--
-- Name: messaging_federation_read_receipts_message_read_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_read_receipts_message_read_at_idx ON public.messaging_federation_read_receipts USING btree (chat_message_id, read_at);


--
-- Name: messaging_federation_read_receipts_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_read_receipts_unique ON public.messaging_federation_read_receipts USING btree (chat_message_id, remote_actor_id);


--
-- Name: messaging_federation_request_replays_expires_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_request_replays_expires_at_idx ON public.messaging_federation_request_replays USING btree (expires_at);


--
-- Name: messaging_federation_request_replays_nonce_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_request_replays_nonce_unique ON public.messaging_federation_request_replays USING btree (nonce);


--
-- Name: messaging_federation_request_replays_origin_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_request_replays_origin_inserted_idx ON public.messaging_federation_request_replays USING btree (origin_domain, inserted_at);


--
-- Name: messaging_federation_room_presence_states_conversation_expires_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_room_presence_states_conversation_expires_ ON public.messaging_federation_room_presence_states USING btree (conversation_id, expires_at_remote);


--
-- Name: messaging_federation_room_presence_states_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_room_presence_states_unique ON public.messaging_federation_room_presence_states USING btree (conversation_id, remote_actor_id);


--
-- Name: messaging_federation_room_presence_states_updated_at_remote_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_federation_room_presence_states_updated_at_remote_idx ON public.messaging_federation_room_presence_states USING btree (updated_at_remote);


--
-- Name: messaging_federation_stream_counters_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_stream_counters_unique ON public.messaging_federation_stream_counters USING btree (stream_id);


--
-- Name: messaging_federation_stream_positions_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_federation_stream_positions_unique ON public.messaging_federation_stream_positions USING btree (origin_domain, stream_id);


--
-- Name: messaging_server_members_server_id_left_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_server_members_server_id_left_at_index ON public.messaging_server_members USING btree (server_id, left_at);


--
-- Name: messaging_server_members_server_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_server_members_server_id_user_id_index ON public.messaging_server_members USING btree (server_id, user_id);


--
-- Name: messaging_server_members_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_server_members_user_id_index ON public.messaging_server_members USING btree (user_id);


--
-- Name: messaging_servers_creator_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_servers_creator_id_index ON public.messaging_servers USING btree (creator_id);


--
-- Name: messaging_servers_federation_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX messaging_servers_federation_id_unique ON public.messaging_servers USING btree (federation_id) WHERE (federation_id IS NOT NULL);


--
-- Name: messaging_servers_is_public_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_servers_is_public_index ON public.messaging_servers USING btree (is_public);


--
-- Name: messaging_servers_member_count_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_servers_member_count_index ON public.messaging_servers USING btree (member_count);


--
-- Name: messaging_servers_origin_domain_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messaging_servers_origin_domain_index ON public.messaging_servers USING btree (origin_domain);


--
-- Name: moderation_actions_action_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderation_actions_action_type_index ON public.moderation_actions USING btree (action_type);


--
-- Name: moderation_actions_conversation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderation_actions_conversation_id_index ON public.moderation_actions USING btree (conversation_id);


--
-- Name: moderation_actions_moderator_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderation_actions_moderator_id_index ON public.moderation_actions USING btree (moderator_id);


--
-- Name: moderation_actions_target_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderation_actions_target_message_id_index ON public.moderation_actions USING btree (target_message_id);


--
-- Name: moderation_actions_target_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderation_actions_target_user_id_index ON public.moderation_actions USING btree (target_user_id);


--
-- Name: moderator_notes_conversation_id_target_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderator_notes_conversation_id_target_user_id_index ON public.moderator_notes USING btree (conversation_id, target_user_id);


--
-- Name: moderator_notes_created_by_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderator_notes_created_by_id_index ON public.moderator_notes USING btree (created_by_id);


--
-- Name: moderator_notes_target_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderator_notes_target_user_id_index ON public.moderator_notes USING btree (target_user_id);


--
-- Name: notifications_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_inserted_at_index ON public.notifications USING btree (inserted_at);


--
-- Name: notifications_source_type_source_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_source_type_source_id_index ON public.notifications USING btree (source_type, source_id);


--
-- Name: notifications_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_user_id_index ON public.notifications USING btree (user_id);


--
-- Name: notifications_user_id_read_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_user_id_read_at_index ON public.notifications USING btree (user_id, read_at);


--
-- Name: notifications_user_id_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_user_id_type_index ON public.notifications USING btree (user_id, type);


--
-- Name: notifications_user_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_user_status_index ON public.notifications USING btree (user_id, read_at, dismissed_at);


--
-- Name: oauth_apps_client_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_apps_client_id_index ON public.oauth_apps USING btree (client_id);


--
-- Name: oauth_apps_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_apps_user_id_index ON public.oauth_apps USING btree (user_id);


--
-- Name: oauth_authorizations_app_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_authorizations_app_id_index ON public.oauth_authorizations USING btree (app_id);


--
-- Name: oauth_authorizations_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_authorizations_token_index ON public.oauth_authorizations USING btree (token);


--
-- Name: oauth_authorizations_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_authorizations_user_id_index ON public.oauth_authorizations USING btree (user_id);


--
-- Name: oauth_tokens_app_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_tokens_app_id_index ON public.oauth_tokens USING btree (app_id);


--
-- Name: oauth_tokens_refresh_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_tokens_refresh_token_index ON public.oauth_tokens USING btree (refresh_token);


--
-- Name: oauth_tokens_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_tokens_token_index ON public.oauth_tokens USING btree (token);


--
-- Name: oauth_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_tokens_user_id_index ON public.oauth_tokens USING btree (user_id);


--
-- Name: oauth_tokens_valid_until_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_tokens_valid_until_index ON public.oauth_tokens USING btree (valid_until);


--
-- Name: oban_jobs_args_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);


--
-- Name: oban_jobs_email_inbound_idempotency_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_email_inbound_idempotency_key_idx ON public.oban_jobs USING btree (worker, queue, ((args ->> 'idempotency_key'::text)), state) WHERE (queue = 'email_inbound'::text);


--
-- Name: oban_jobs_meta_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);


--
-- Name: oban_jobs_state_queue_priority_scheduled_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);


--
-- Name: oidc_signing_keys_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oidc_signing_keys_active_index ON public.oidc_signing_keys USING btree (active);


--
-- Name: oidc_signing_keys_kid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oidc_signing_keys_kid_index ON public.oidc_signing_keys USING btree (kid);


--
-- Name: passkey_credentials_credential_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX passkey_credentials_credential_id_index ON public.passkey_credentials USING btree (credential_id);


--
-- Name: passkey_credentials_user_handle_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX passkey_credentials_user_handle_index ON public.passkey_credentials USING btree (user_handle);


--
-- Name: passkey_credentials_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX passkey_credentials_user_id_index ON public.passkey_credentials USING btree (user_id);


--
-- Name: password_vault_entries_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX password_vault_entries_user_id_index ON public.password_vault_entries USING btree (user_id);


--
-- Name: password_vault_entries_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX password_vault_entries_user_id_inserted_at_index ON public.password_vault_entries USING btree (user_id, inserted_at);


--
-- Name: password_vault_settings_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX password_vault_settings_user_id_index ON public.password_vault_settings USING btree (user_id);


--
-- Name: pgp_key_cache_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pgp_key_cache_email_index ON public.pgp_key_cache USING btree (email);


--
-- Name: pgp_key_cache_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pgp_key_cache_expires_at_index ON public.pgp_key_cache USING btree (expires_at);


--
-- Name: platform_updates_created_by_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_updates_created_by_id_index ON public.platform_updates USING btree (created_by_id);


--
-- Name: platform_updates_published_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_updates_published_inserted_at_index ON public.platform_updates USING btree (published, inserted_at);


--
-- Name: poll_options_poll_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX poll_options_poll_id_index ON public.poll_options USING btree (poll_id);


--
-- Name: poll_votes_option_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX poll_votes_option_id_index ON public.poll_votes USING btree (option_id);


--
-- Name: poll_votes_poll_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX poll_votes_poll_id_index ON public.poll_votes USING btree (poll_id);


--
-- Name: poll_votes_poll_id_user_id_option_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX poll_votes_poll_id_user_id_option_id_index ON public.poll_votes USING btree (poll_id, user_id, option_id);


--
-- Name: poll_votes_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX poll_votes_user_id_index ON public.poll_votes USING btree (user_id);


--
-- Name: polls_last_fetched_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX polls_last_fetched_at_index ON public.polls USING btree (last_fetched_at);


--
-- Name: polls_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX polls_message_id_index ON public.polls USING btree (message_id);


--
-- Name: polls_voter_uris_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX polls_voter_uris_index ON public.polls USING gin (voter_uris);


--
-- Name: post_boosts_activitypub_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_boosts_activitypub_id_index ON public.post_boosts USING btree (activitypub_id);


--
-- Name: post_boosts_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_boosts_message_id_index ON public.post_boosts USING btree (message_id);


--
-- Name: post_boosts_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_boosts_user_id_index ON public.post_boosts USING btree (user_id);


--
-- Name: post_boosts_user_id_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX post_boosts_user_id_message_id_index ON public.post_boosts USING btree (user_id, message_id);


--
-- Name: post_dismissals_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_dismissals_message_id_index ON public.post_dismissals USING btree (message_id);


--
-- Name: post_dismissals_user_id_dismissal_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_dismissals_user_id_dismissal_type_index ON public.post_dismissals USING btree (user_id, dismissal_type);


--
-- Name: post_dismissals_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_dismissals_user_id_index ON public.post_dismissals USING btree (user_id);


--
-- Name: post_dismissals_user_id_message_id_dismissal_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX post_dismissals_user_id_message_id_dismissal_type_index ON public.post_dismissals USING btree (user_id, message_id, dismissal_type);


--
-- Name: post_hashtags_hashtag_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_hashtags_hashtag_id_index ON public.post_hashtags USING btree (hashtag_id);


--
-- Name: post_hashtags_hashtag_message_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_hashtags_hashtag_message_idx ON public.post_hashtags USING btree (hashtag_id, message_id);


--
-- Name: post_hashtags_message_id_hashtag_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX post_hashtags_message_id_hashtag_id_index ON public.post_hashtags USING btree (message_id, hashtag_id);


--
-- Name: post_likes_by_message_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_likes_by_message_idx ON public.post_likes USING btree (message_id, created_at);


--
-- Name: post_likes_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_likes_message_id_index ON public.post_likes USING btree (message_id);


--
-- Name: post_likes_user_id_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX post_likes_user_id_message_id_index ON public.post_likes USING btree (user_id, message_id);


--
-- Name: post_views_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_views_inserted_at_index ON public.post_views USING btree (inserted_at);


--
-- Name: post_views_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_views_message_id_index ON public.post_views USING btree (message_id);


--
-- Name: post_views_message_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_views_message_index ON public.post_views USING btree (message_id);


--
-- Name: post_views_user_id_dwell_time_ms_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_views_user_id_dwell_time_ms_index ON public.post_views USING btree (user_id, dwell_time_ms);


--
-- Name: post_views_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_views_user_id_index ON public.post_views USING btree (user_id);


--
-- Name: post_views_user_id_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX post_views_user_id_message_id_index ON public.post_views USING btree (user_id, message_id);


--
-- Name: post_views_user_message_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_views_user_message_index ON public.post_views USING btree (user_id, message_id);


--
-- Name: profile_custom_domains_domain_ci_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX profile_custom_domains_domain_ci_unique ON public.profile_custom_domains USING btree (lower((domain)::text));


--
-- Name: profile_custom_domains_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_custom_domains_status_index ON public.profile_custom_domains USING btree (status);


--
-- Name: profile_custom_domains_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_custom_domains_user_id_index ON public.profile_custom_domains USING btree (user_id);


--
-- Name: profile_links_is_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_links_is_active_index ON public.profile_links USING btree (is_active);


--
-- Name: profile_links_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_links_position_index ON public.profile_links USING btree ("position");


--
-- Name: profile_links_profile_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_links_profile_id_index ON public.profile_links USING btree (profile_id);


--
-- Name: profile_site_visits_profile_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_site_visits_profile_user_id_index ON public.profile_site_visits USING btree (profile_user_id);


--
-- Name: profile_site_visits_profile_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_site_visits_profile_user_id_inserted_at_index ON public.profile_site_visits USING btree (profile_user_id, inserted_at);


--
-- Name: profile_site_visits_profile_user_id_request_host_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_site_visits_profile_user_id_request_host_index ON public.profile_site_visits USING btree (profile_user_id, request_host);


--
-- Name: profile_site_visits_profile_user_id_request_host_inserted_at_in; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_site_visits_profile_user_id_request_host_inserted_at_in ON public.profile_site_visits USING btree (profile_user_id, request_host, inserted_at);


--
-- Name: profile_views_profile_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_views_profile_user_id_index ON public.profile_views USING btree (profile_user_id);


--
-- Name: profile_views_profile_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_views_profile_user_id_inserted_at_index ON public.profile_views USING btree (profile_user_id, inserted_at);


--
-- Name: profile_views_profile_user_id_viewer_session_id_inserted_at_ind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_views_profile_user_id_viewer_session_id_inserted_at_ind ON public.profile_views USING btree (profile_user_id, viewer_session_id, inserted_at);


--
-- Name: profile_views_profile_user_id_viewer_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_views_profile_user_id_viewer_user_id_inserted_at_index ON public.profile_views USING btree (profile_user_id, viewer_user_id, inserted_at);


--
-- Name: profile_views_viewer_session_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_views_viewer_session_id_index ON public.profile_views USING btree (viewer_session_id);


--
-- Name: profile_views_viewer_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_views_viewer_user_id_index ON public.profile_views USING btree (viewer_user_id);


--
-- Name: profile_widgets_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_widgets_position_index ON public.profile_widgets USING btree ("position");


--
-- Name: profile_widgets_profile_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_widgets_profile_id_index ON public.profile_widgets USING btree (profile_id);


--
-- Name: profile_widgets_widget_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profile_widgets_widget_type_index ON public.profile_widgets USING btree (widget_type);


--
-- Name: registration_checkouts_lookup_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX registration_checkouts_lookup_token_index ON public.registration_checkouts USING btree (lookup_token);


--
-- Name: registration_checkouts_product_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX registration_checkouts_product_slug_index ON public.registration_checkouts USING btree (product_slug);


--
-- Name: registration_checkouts_redeemed_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX registration_checkouts_redeemed_at_index ON public.registration_checkouts USING btree (redeemed_at);


--
-- Name: registration_checkouts_redeemed_by_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX registration_checkouts_redeemed_by_user_id_index ON public.registration_checkouts USING btree (redeemed_by_user_id);


--
-- Name: registration_checkouts_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX registration_checkouts_status_index ON public.registration_checkouts USING btree (status);


--
-- Name: registration_checkouts_stripe_checkout_session_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX registration_checkouts_stripe_checkout_session_id_index ON public.registration_checkouts USING btree (stripe_checkout_session_id);


--
-- Name: remote_interactions_message_id_actor_uri_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX remote_interactions_message_id_actor_uri_index ON public.remote_interactions USING btree (message_id, actor_uri);


--
-- Name: remote_interactions_message_id_emoji_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX remote_interactions_message_id_emoji_index ON public.remote_interactions USING btree (message_id, emoji) WHERE ((interaction_type)::text = 'emoji_react'::text);


--
-- Name: remote_interactions_message_id_interaction_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX remote_interactions_message_id_interaction_type_index ON public.remote_interactions USING btree (message_id, interaction_type);


--
-- Name: remote_interactions_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX remote_interactions_unique_index ON public.remote_interactions USING btree (message_id, actor_uri, interaction_type, emoji);


--
-- Name: reports_priority_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_priority_index ON public.reports USING btree (priority);


--
-- Name: reports_reportable_type_reportable_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_reportable_type_reportable_id_index ON public.reports USING btree (reportable_type, reportable_id);


--
-- Name: reports_reporter_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_reporter_id_index ON public.reports USING btree (reporter_id);


--
-- Name: reports_reviewed_by_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_reviewed_by_id_index ON public.reports USING btree (reviewed_by_id);


--
-- Name: reports_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_status_index ON public.reports USING btree (status);


--
-- Name: reports_unique_pending_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX reports_unique_pending_index ON public.reports USING btree (reporter_id, reportable_type, reportable_id, status) WHERE ((status)::text = 'pending'::text);


--
-- Name: rss_feeds_last_fetched_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rss_feeds_last_fetched_at_index ON public.rss_feeds USING btree (last_fetched_at);


--
-- Name: rss_feeds_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rss_feeds_status_index ON public.rss_feeds USING btree (status);


--
-- Name: rss_feeds_url_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rss_feeds_url_index ON public.rss_feeds USING btree (url);


--
-- Name: rss_items_feed_id_guid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rss_items_feed_id_guid_index ON public.rss_items USING btree (feed_id, guid);


--
-- Name: rss_items_feed_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rss_items_feed_id_index ON public.rss_items USING btree (feed_id);


--
-- Name: rss_items_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rss_items_inserted_at_index ON public.rss_items USING btree (inserted_at);


--
-- Name: rss_items_published_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rss_items_published_at_index ON public.rss_items USING btree (published_at);


--
-- Name: rss_subscriptions_feed_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rss_subscriptions_feed_id_index ON public.rss_subscriptions USING btree (feed_id);


--
-- Name: rss_subscriptions_user_id_feed_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rss_subscriptions_user_id_feed_id_index ON public.rss_subscriptions USING btree (user_id, feed_id);


--
-- Name: rss_subscriptions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rss_subscriptions_user_id_index ON public.rss_subscriptions USING btree (user_id);


--
-- Name: saved_items_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX saved_items_inserted_at_index ON public.saved_items USING btree (inserted_at);


--
-- Name: saved_items_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX saved_items_user_id_index ON public.saved_items USING btree (user_id);


--
-- Name: saved_items_user_message_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX saved_items_user_message_unique ON public.saved_items USING btree (user_id, message_id) WHERE (message_id IS NOT NULL);


--
-- Name: saved_items_user_rss_item_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX saved_items_user_rss_item_unique ON public.saved_items USING btree (user_id, rss_item_id) WHERE (rss_item_id IS NOT NULL);


--
-- Name: signing_keys_remote_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX signing_keys_remote_actor_id_index ON public.signing_keys USING btree (remote_actor_id) WHERE (remote_actor_id IS NOT NULL);


--
-- Name: signing_keys_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX signing_keys_user_id_index ON public.signing_keys USING btree (user_id) WHERE (user_id IS NOT NULL);


--
-- Name: static_site_files_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX static_site_files_user_id_index ON public.static_site_files USING btree (user_id);


--
-- Name: static_site_files_user_id_path_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX static_site_files_user_id_path_index ON public.static_site_files USING btree (user_id, path);


--
-- Name: stored_files_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stored_files_user_id_index ON public.stored_files USING btree (user_id);


--
-- Name: stored_files_user_id_path_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX stored_files_user_id_path_index ON public.stored_files USING btree (user_id, path);


--
-- Name: stored_folders_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stored_folders_user_id_index ON public.stored_folders USING btree (user_id);


--
-- Name: stored_folders_user_id_path_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX stored_folders_user_id_path_index ON public.stored_folders USING btree (user_id, path);


--
-- Name: subscription_products_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscription_products_active_index ON public.subscription_products USING btree (active);


--
-- Name: subscription_products_billing_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscription_products_billing_type_index ON public.subscription_products USING btree (billing_type);


--
-- Name: subscription_products_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscription_products_slug_index ON public.subscription_products USING btree (slug);


--
-- Name: subscriptions_product_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscriptions_product_index ON public.subscriptions USING btree (product);


--
-- Name: subscriptions_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscriptions_status_index ON public.subscriptions USING btree (status);


--
-- Name: subscriptions_stripe_customer_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscriptions_stripe_customer_id_index ON public.subscriptions USING btree (stripe_customer_id);


--
-- Name: subscriptions_stripe_subscription_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscriptions_stripe_subscription_id_index ON public.subscriptions USING btree (stripe_subscription_id) WHERE (stripe_subscription_id IS NOT NULL);


--
-- Name: subscriptions_user_id_product_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscriptions_user_id_product_index ON public.subscriptions USING btree (user_id, product);


--
-- Name: system_config_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX system_config_key_index ON public.system_config USING btree (key);


--
-- Name: trust_level_logs_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX trust_level_logs_inserted_at_index ON public.trust_level_logs USING btree (inserted_at);


--
-- Name: trust_level_logs_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX trust_level_logs_user_id_index ON public.trust_level_logs USING btree (user_id);


--
-- Name: trusted_devices_device_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX trusted_devices_device_token_index ON public.trusted_devices USING btree (device_token);


--
-- Name: trusted_devices_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX trusted_devices_expires_at_index ON public.trusted_devices USING btree (expires_at);


--
-- Name: trusted_devices_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX trusted_devices_user_id_index ON public.trusted_devices USING btree (user_id);


--
-- Name: user_activity_stats_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_activity_stats_user_id_index ON public.user_activity_stats USING btree (user_id);


--
-- Name: user_badges_badge_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_badges_badge_type_index ON public.user_badges USING btree (badge_type);


--
-- Name: user_badges_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_badges_user_id_index ON public.user_badges USING btree (user_id);


--
-- Name: user_blocks_blocked_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_blocks_blocked_id_index ON public.user_blocks USING btree (blocked_id);


--
-- Name: user_blocks_blocker_id_blocked_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_blocks_blocker_id_blocked_id_index ON public.user_blocks USING btree (blocker_id, blocked_id);


--
-- Name: user_blocks_blocker_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_blocks_blocker_id_index ON public.user_blocks USING btree (blocker_id);


--
-- Name: user_hidden_messages_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_hidden_messages_message_id_index ON public.user_hidden_messages USING btree (message_id);


--
-- Name: user_hidden_messages_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_hidden_messages_user_id_index ON public.user_hidden_messages USING btree (user_id);


--
-- Name: user_hidden_messages_user_id_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_hidden_messages_user_id_message_id_index ON public.user_hidden_messages USING btree (user_id, message_id);


--
-- Name: user_integrations_provider_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_integrations_provider_index ON public.user_integrations USING btree (provider);


--
-- Name: user_integrations_user_id_provider_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_integrations_user_id_provider_index ON public.user_integrations USING btree (user_id, provider);


--
-- Name: user_mutes_muted_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_mutes_muted_id_index ON public.user_mutes USING btree (muted_id);


--
-- Name: user_mutes_muter_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_mutes_muter_id_index ON public.user_mutes USING btree (muter_id);


--
-- Name: user_mutes_muter_id_muted_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_mutes_muter_id_muted_id_index ON public.user_mutes USING btree (muter_id, muted_id);


--
-- Name: user_post_timestamps_conversation_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_post_timestamps_conversation_id_user_id_index ON public.user_post_timestamps USING btree (conversation_id, user_id);


--
-- Name: user_post_timestamps_last_post_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_post_timestamps_last_post_at_index ON public.user_post_timestamps USING btree (last_post_at);


--
-- Name: user_profiles_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_profiles_user_id_index ON public.user_profiles USING btree (user_id);


--
-- Name: user_timeouts_conversation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_timeouts_conversation_id_index ON public.user_timeouts USING btree (conversation_id);


--
-- Name: user_timeouts_timeout_until_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_timeouts_timeout_until_index ON public.user_timeouts USING btree (timeout_until);


--
-- Name: user_timeouts_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_timeouts_user_id_index ON public.user_timeouts USING btree (user_id);


--
-- Name: user_warnings_conversation_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_warnings_conversation_id_user_id_index ON public.user_warnings USING btree (conversation_id, user_id);


--
-- Name: user_warnings_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_warnings_user_id_index ON public.user_warnings USING btree (user_id);


--
-- Name: user_warnings_warned_by_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_warnings_warned_by_id_index ON public.user_warnings USING btree (warned_by_id);


--
-- Name: username_history_user_id_changed_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX username_history_user_id_changed_at_index ON public.username_history USING btree (user_id, changed_at);


--
-- Name: username_history_username_changed_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX username_history_username_changed_at_index ON public.username_history USING btree (username, changed_at);


--
-- Name: username_history_username_user_id_changed_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX username_history_username_user_id_changed_at_index ON public.username_history USING btree (username, user_id, changed_at);


--
-- Name: users_bluesky_did_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_bluesky_did_index ON public.users USING btree (bluesky_did);


--
-- Name: users_bluesky_enabled_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_bluesky_enabled_index ON public.users USING btree (bluesky_enabled);


--
-- Name: users_bluesky_identifier_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_bluesky_identifier_index ON public.users USING btree (bluesky_identifier);


--
-- Name: users_email_sending_restricted_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_email_sending_restricted_index ON public.users USING btree (email_sending_restricted) WHERE (email_sending_restricted = true);


--
-- Name: users_handle_ci_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_handle_ci_unique ON public.users USING btree (lower((handle)::text));


--
-- Name: users_handle_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_handle_index ON public.users USING btree (handle);


--
-- Name: users_last_imap_access_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_last_imap_access_index ON public.users USING btree (last_imap_access);


--
-- Name: users_last_login_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_last_login_at_index ON public.users USING btree (last_login_at);


--
-- Name: users_last_login_ip_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_last_login_ip_index ON public.users USING btree (last_login_ip);


--
-- Name: users_last_password_change_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_last_password_change_index ON public.users USING btree (last_password_change);


--
-- Name: users_last_pop3_access_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_last_pop3_access_index ON public.users USING btree (last_pop3_access);


--
-- Name: users_last_seen_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_last_seen_at_index ON public.users USING btree (last_seen_at);


--
-- Name: users_onboarding_completed_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_onboarding_completed_index ON public.users USING btree (onboarding_completed);


--
-- Name: users_password_reset_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_password_reset_token_index ON public.users USING btree (password_reset_token);


--
-- Name: users_pgp_fingerprint_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_pgp_fingerprint_index ON public.users USING btree (pgp_fingerprint);


--
-- Name: users_pgp_wkd_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_pgp_wkd_hash_index ON public.users USING btree (pgp_wkd_hash) WHERE (pgp_wkd_hash IS NOT NULL);


--
-- Name: users_registered_via_onion_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_registered_via_onion_index ON public.users USING btree (registered_via_onion);


--
-- Name: users_registration_ip_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_registration_ip_index ON public.users USING btree (registration_ip);


--
-- Name: users_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_status_index ON public.users USING btree (status);


--
-- Name: users_storage_used_bytes_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_storage_used_bytes_index ON public.users USING btree (storage_used_bytes);


--
-- Name: users_stripe_customer_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_stripe_customer_id_index ON public.users USING btree (stripe_customer_id) WHERE (stripe_customer_id IS NOT NULL);


--
-- Name: users_suspended_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_suspended_index ON public.users USING btree (suspended);


--
-- Name: users_suspended_until_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_suspended_until_index ON public.users USING btree (suspended_until);


--
-- Name: users_unique_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_unique_id_index ON public.users USING btree (unique_id);


--
-- Name: users_username_ci_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_username_ci_unique ON public.users USING btree (lower((username)::text));


--
-- Name: vpn_connection_logs_connected_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vpn_connection_logs_connected_at_index ON public.vpn_connection_logs USING btree (connected_at);


--
-- Name: vpn_connection_logs_vpn_user_config_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vpn_connection_logs_vpn_user_config_id_index ON public.vpn_connection_logs USING btree (vpn_user_config_id);


--
-- Name: vpn_servers_country_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vpn_servers_country_code_index ON public.vpn_servers USING btree (country_code);


--
-- Name: vpn_servers_minimum_trust_level_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vpn_servers_minimum_trust_level_index ON public.vpn_servers USING btree (minimum_trust_level);


--
-- Name: vpn_servers_public_ip_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vpn_servers_public_ip_index ON public.vpn_servers USING btree (public_ip);


--
-- Name: vpn_servers_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vpn_servers_status_index ON public.vpn_servers USING btree (status);


--
-- Name: vpn_user_configs_public_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vpn_user_configs_public_key_index ON public.vpn_user_configs USING btree (public_key);


--
-- Name: vpn_user_configs_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vpn_user_configs_status_index ON public.vpn_user_configs USING btree (status);


--
-- Name: vpn_user_configs_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vpn_user_configs_user_id_index ON public.vpn_user_configs USING btree (user_id);


--
-- Name: vpn_user_configs_user_id_vpn_server_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vpn_user_configs_user_id_vpn_server_id_index ON public.vpn_user_configs USING btree (user_id, vpn_server_id);


--
-- Name: vpn_user_configs_vpn_server_id_allocated_ip_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vpn_user_configs_vpn_server_id_allocated_ip_index ON public.vpn_user_configs USING btree (vpn_server_id, allocated_ip);


--
-- Name: vpn_user_configs_vpn_server_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vpn_user_configs_vpn_server_id_index ON public.vpn_user_configs USING btree (vpn_server_id);


--
-- Name: account_deletion_requests account_deletion_requests_reviewed_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_deletion_requests
    ADD CONSTRAINT account_deletion_requests_reviewed_by_id_fkey FOREIGN KEY (reviewed_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: account_deletion_requests account_deletion_requests_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_deletion_requests
    ADD CONSTRAINT account_deletion_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: activitypub_activities activitypub_activities_internal_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_activities
    ADD CONSTRAINT activitypub_activities_internal_message_id_fkey FOREIGN KEY (internal_message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: activitypub_activities activitypub_activities_internal_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_activities
    ADD CONSTRAINT activitypub_activities_internal_user_id_fkey FOREIGN KEY (internal_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: activitypub_actors activitypub_actors_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_actors
    ADD CONSTRAINT activitypub_actors_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: activitypub_deliveries activitypub_deliveries_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_deliveries
    ADD CONSTRAINT activitypub_deliveries_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activitypub_activities(id) ON DELETE CASCADE;


--
-- Name: activitypub_instances activitypub_instances_blocked_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_instances
    ADD CONSTRAINT activitypub_instances_blocked_by_id_fkey FOREIGN KEY (blocked_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: activitypub_instances activitypub_instances_policy_applied_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_instances
    ADD CONSTRAINT activitypub_instances_policy_applied_by_id_fkey FOREIGN KEY (policy_applied_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: activitypub_relay_subscriptions activitypub_relay_subscriptions_subscribed_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_relay_subscriptions
    ADD CONSTRAINT activitypub_relay_subscriptions_subscribed_by_id_fkey FOREIGN KEY (subscribed_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: activitypub_user_blocks activitypub_user_blocks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activitypub_user_blocks
    ADD CONSTRAINT activitypub_user_blocks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: announcement_dismissals announcement_dismissals_announcement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcement_dismissals
    ADD CONSTRAINT announcement_dismissals_announcement_id_fkey FOREIGN KEY (announcement_id) REFERENCES public.announcements(id) ON DELETE CASCADE;


--
-- Name: announcement_dismissals announcement_dismissals_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcement_dismissals
    ADD CONSTRAINT announcement_dismissals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: announcements announcements_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: api_tokens api_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_tokens
    ADD CONSTRAINT api_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: app_passwords app_passwords_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_passwords
    ADD CONSTRAINT app_passwords_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: audit_logs audit_logs_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: audit_logs audit_logs_target_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: auto_mod_rules auto_mod_rules_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auto_mod_rules
    ADD CONSTRAINT auto_mod_rules_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: auto_mod_rules auto_mod_rules_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auto_mod_rules
    ADD CONSTRAINT auto_mod_rules_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: bluesky_inbound_events bluesky_inbound_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bluesky_inbound_events
    ADD CONSTRAINT bluesky_inbound_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: calendar_events calendar_events_calendar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendar_events
    ADD CONSTRAINT calendar_events_calendar_id_fkey FOREIGN KEY (calendar_id) REFERENCES public.calendars(id) ON DELETE CASCADE;


--
-- Name: calendars calendars_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calendars
    ADD CONSTRAINT calendars_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: calls calls_callee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calls
    ADD CONSTRAINT calls_callee_id_fkey FOREIGN KEY (callee_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: calls calls_caller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calls
    ADD CONSTRAINT calls_caller_id_fkey FOREIGN KEY (caller_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: calls calls_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calls
    ADD CONSTRAINT calls_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: chat_conversation_members chat_conversation_members_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversation_members
    ADD CONSTRAINT chat_conversation_members_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: chat_conversation_members chat_conversation_members_last_read_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversation_members
    ADD CONSTRAINT chat_conversation_members_last_read_message_id_fkey FOREIGN KEY (last_read_message_id) REFERENCES public.chat_messages(id) ON DELETE SET NULL;


--
-- Name: chat_conversation_members chat_conversation_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversation_members
    ADD CONSTRAINT chat_conversation_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: chat_conversations chat_conversations_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: chat_conversations chat_conversations_remote_group_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_remote_group_actor_id_fkey FOREIGN KEY (remote_group_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE SET NULL;


--
-- Name: chat_conversations chat_conversations_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_conversations
    ADD CONSTRAINT chat_conversations_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.messaging_servers(id) ON DELETE CASCADE;


--
-- Name: chat_message_reactions chat_message_reactions_chat_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_reactions
    ADD CONSTRAINT chat_message_reactions_chat_message_id_fkey FOREIGN KEY (chat_message_id) REFERENCES public.chat_messages(id) ON DELETE CASCADE;


--
-- Name: chat_message_reactions chat_message_reactions_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_reactions
    ADD CONSTRAINT chat_message_reactions_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: chat_message_reactions chat_message_reactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_reactions
    ADD CONSTRAINT chat_message_reactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: chat_message_reads chat_message_reads_chat_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_reads
    ADD CONSTRAINT chat_message_reads_chat_message_id_fkey FOREIGN KEY (chat_message_id) REFERENCES public.chat_messages(id) ON DELETE CASCADE;


--
-- Name: chat_message_reads chat_message_reads_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_reads
    ADD CONSTRAINT chat_message_reads_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: chat_messages chat_messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: chat_messages chat_messages_link_preview_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_link_preview_id_fkey FOREIGN KEY (link_preview_id) REFERENCES public.link_previews(id) ON DELETE SET NULL;


--
-- Name: chat_messages chat_messages_reply_to_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_reply_to_id_fkey FOREIGN KEY (reply_to_id) REFERENCES public.chat_messages(id) ON DELETE SET NULL;


--
-- Name: chat_messages chat_messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: chat_moderation_actions chat_moderation_actions_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_moderation_actions
    ADD CONSTRAINT chat_moderation_actions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: chat_moderation_actions chat_moderation_actions_moderator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_moderation_actions
    ADD CONSTRAINT chat_moderation_actions_moderator_id_fkey FOREIGN KEY (moderator_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: chat_moderation_actions chat_moderation_actions_target_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_moderation_actions
    ADD CONSTRAINT chat_moderation_actions_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: chat_user_hidden_messages chat_user_hidden_messages_chat_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_user_hidden_messages
    ADD CONSTRAINT chat_user_hidden_messages_chat_message_id_fkey FOREIGN KEY (chat_message_id) REFERENCES public.chat_messages(id) ON DELETE CASCADE;


--
-- Name: chat_user_hidden_messages chat_user_hidden_messages_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_user_hidden_messages
    ADD CONSTRAINT chat_user_hidden_messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: chat_user_timeouts chat_user_timeouts_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_user_timeouts
    ADD CONSTRAINT chat_user_timeouts_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: chat_user_timeouts chat_user_timeouts_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_user_timeouts
    ADD CONSTRAINT chat_user_timeouts_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: chat_user_timeouts chat_user_timeouts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_user_timeouts
    ADD CONSTRAINT chat_user_timeouts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: community_bans community_bans_banned_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_bans
    ADD CONSTRAINT community_bans_banned_by_id_fkey FOREIGN KEY (banned_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: community_bans community_bans_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_bans
    ADD CONSTRAINT community_bans_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: community_bans community_bans_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_bans
    ADD CONSTRAINT community_bans_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: community_flairs community_flairs_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_flairs
    ADD CONSTRAINT community_flairs_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: contact_groups contact_groups_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_groups
    ADD CONSTRAINT contact_groups_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: contacts contacts_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.contact_groups(id) ON DELETE SET NULL;


--
-- Name: contacts contacts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: conversation_members conversation_members_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members
    ADD CONSTRAINT conversation_members_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: conversation_members conversation_members_last_read_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members
    ADD CONSTRAINT conversation_members_last_read_message_id_fkey FOREIGN KEY (last_read_message_id) REFERENCES public.messages(id) ON DELETE SET NULL;


--
-- Name: conversation_members conversation_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members
    ADD CONSTRAINT conversation_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: conversations conversations_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: conversations conversations_remote_group_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_remote_group_actor_id_fkey FOREIGN KEY (remote_group_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE SET NULL;


--
-- Name: conversations conversations_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.messaging_servers(id) ON DELETE CASCADE;


--
-- Name: creator_satisfaction creator_satisfaction_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creator_satisfaction
    ADD CONSTRAINT creator_satisfaction_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: creator_satisfaction creator_satisfaction_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creator_satisfaction
    ADD CONSTRAINT creator_satisfaction_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: creator_satisfaction creator_satisfaction_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.creator_satisfaction
    ADD CONSTRAINT creator_satisfaction_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: data_exports data_exports_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_exports
    ADD CONSTRAINT data_exports_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: developer_webhook_deliveries developer_webhook_deliveries_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.developer_webhook_deliveries
    ADD CONSTRAINT developer_webhook_deliveries_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: developer_webhook_deliveries developer_webhook_deliveries_webhook_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.developer_webhook_deliveries
    ADD CONSTRAINT developer_webhook_deliveries_webhook_id_fkey FOREIGN KEY (webhook_id) REFERENCES public.developer_webhooks(id) ON DELETE CASCADE;


--
-- Name: developer_webhooks developer_webhooks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.developer_webhooks
    ADD CONSTRAINT developer_webhooks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: device_tokens device_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: dns_query_stats dns_query_stats_zone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_query_stats
    ADD CONSTRAINT dns_query_stats_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES public.dns_zones(id) ON DELETE CASCADE;


--
-- Name: dns_records dns_records_zone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_records
    ADD CONSTRAINT dns_records_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES public.dns_zones(id) ON DELETE CASCADE;


--
-- Name: dns_zone_service_configs dns_zone_service_configs_zone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zone_service_configs
    ADD CONSTRAINT dns_zone_service_configs_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES public.dns_zones(id) ON DELETE CASCADE;


--
-- Name: dns_zones dns_zones_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dns_zones
    ADD CONSTRAINT dns_zones_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_aliases email_aliases_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_aliases
    ADD CONSTRAINT email_aliases_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_auto_replies email_auto_replies_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_auto_replies
    ADD CONSTRAINT email_auto_replies_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_auto_reply_log email_auto_reply_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_auto_reply_log
    ADD CONSTRAINT email_auto_reply_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_blocked_senders email_blocked_senders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_blocked_senders
    ADD CONSTRAINT email_blocked_senders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_category_preferences email_category_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_category_preferences
    ADD CONSTRAINT email_category_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_custom_domains email_custom_domains_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_custom_domains
    ADD CONSTRAINT email_custom_domains_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_exports email_exports_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_exports
    ADD CONSTRAINT email_exports_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_filters email_filters_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_filters
    ADD CONSTRAINT email_filters_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_folders email_folders_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_folders
    ADD CONSTRAINT email_folders_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.email_folders(id) ON DELETE SET NULL;


--
-- Name: email_folders email_folders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_folders
    ADD CONSTRAINT email_folders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_jobs email_jobs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_jobs
    ADD CONSTRAINT email_jobs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_labels email_labels_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_labels
    ADD CONSTRAINT email_labels_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_message_labels email_message_labels_label_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_labels
    ADD CONSTRAINT email_message_labels_label_id_fkey FOREIGN KEY (label_id) REFERENCES public.email_labels(id) ON DELETE CASCADE;


--
-- Name: email_message_labels email_message_labels_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_message_labels
    ADD CONSTRAINT email_message_labels_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.email_messages(id) ON DELETE CASCADE;


--
-- Name: email_messages email_messages_folder_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_messages
    ADD CONSTRAINT email_messages_folder_id_fkey FOREIGN KEY (folder_id) REFERENCES public.email_folders(id) ON DELETE SET NULL;


--
-- Name: email_messages email_messages_thread_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_messages
    ADD CONSTRAINT email_messages_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES public.email_threads(id) ON DELETE SET NULL;


--
-- Name: email_safe_senders email_safe_senders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_safe_senders
    ADD CONSTRAINT email_safe_senders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_submissions email_submissions_email_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_submissions
    ADD CONSTRAINT email_submissions_email_id_fkey FOREIGN KEY (email_id) REFERENCES public.email_messages(id) ON DELETE SET NULL;


--
-- Name: email_submissions email_submissions_mailbox_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_submissions
    ADD CONSTRAINT email_submissions_mailbox_id_fkey FOREIGN KEY (mailbox_id) REFERENCES public.mailboxes(id) ON DELETE CASCADE;


--
-- Name: email_suppressions email_suppressions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_suppressions
    ADD CONSTRAINT email_suppressions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_templates email_templates_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates
    ADD CONSTRAINT email_templates_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: email_threads email_threads_mailbox_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_threads
    ADD CONSTRAINT email_threads_mailbox_id_fkey FOREIGN KEY (mailbox_id) REFERENCES public.mailboxes(id) ON DELETE CASCADE;


--
-- Name: email_unsubscribes email_unsubscribes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_unsubscribes
    ADD CONSTRAINT email_unsubscribes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: federated_boosts federated_boosts_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_boosts
    ADD CONSTRAINT federated_boosts_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: federated_boosts federated_boosts_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_boosts
    ADD CONSTRAINT federated_boosts_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: federated_dislikes federated_dislikes_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_dislikes
    ADD CONSTRAINT federated_dislikes_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: federated_dislikes federated_dislikes_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_dislikes
    ADD CONSTRAINT federated_dislikes_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: federated_likes federated_likes_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_likes
    ADD CONSTRAINT federated_likes_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: federated_likes federated_likes_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_likes
    ADD CONSTRAINT federated_likes_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: federated_quotes federated_quotes_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_quotes
    ADD CONSTRAINT federated_quotes_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: federated_quotes federated_quotes_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.federated_quotes
    ADD CONSTRAINT federated_quotes_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: file_shares file_shares_stored_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_shares
    ADD CONSTRAINT file_shares_stored_file_id_fkey FOREIGN KEY (stored_file_id) REFERENCES public.stored_files(id) ON DELETE CASCADE;


--
-- Name: file_shares file_shares_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_shares
    ADD CONSTRAINT file_shares_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: follows follows_followed_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_followed_id_fkey FOREIGN KEY (followed_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: follows follows_follower_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_follower_id_fkey FOREIGN KEY (follower_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: follows follows_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: forwarded_messages forwarded_messages_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.forwarded_messages
    ADD CONSTRAINT forwarded_messages_alias_id_fkey FOREIGN KEY (alias_id) REFERENCES public.email_aliases(id);


--
-- Name: friend_requests friend_requests_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friend_requests
    ADD CONSTRAINT friend_requests_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: friend_requests friend_requests_requester_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friend_requests
    ADD CONSTRAINT friend_requests_requester_id_fkey FOREIGN KEY (requester_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: group_follows group_follows_group_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_follows
    ADD CONSTRAINT group_follows_group_actor_id_fkey FOREIGN KEY (group_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: group_follows group_follows_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_follows
    ADD CONSTRAINT group_follows_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: handle_history handle_history_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handle_history
    ADD CONSTRAINT handle_history_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: hashtag_follows hashtag_follows_hashtag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hashtag_follows
    ADD CONSTRAINT hashtag_follows_hashtag_id_fkey FOREIGN KEY (hashtag_id) REFERENCES public.hashtags(id) ON DELETE CASCADE;


--
-- Name: hashtag_follows hashtag_follows_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hashtag_follows
    ADD CONSTRAINT hashtag_follows_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: imap_subscriptions imap_subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.imap_subscriptions
    ADD CONSTRAINT imap_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: invite_code_uses invite_code_uses_invite_code_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_code_uses
    ADD CONSTRAINT invite_code_uses_invite_code_id_fkey FOREIGN KEY (invite_code_id) REFERENCES public.invite_codes(id) ON DELETE CASCADE;


--
-- Name: invite_code_uses invite_code_uses_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_code_uses
    ADD CONSTRAINT invite_code_uses_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: invite_codes invite_codes_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_codes
    ADD CONSTRAINT invite_codes_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: jmap_email_changes jmap_email_changes_mailbox_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jmap_email_changes
    ADD CONSTRAINT jmap_email_changes_mailbox_id_fkey FOREIGN KEY (mailbox_id) REFERENCES public.mailboxes(id) ON DELETE CASCADE;


--
-- Name: jmap_email_tombstones jmap_email_tombstones_mailbox_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jmap_email_tombstones
    ADD CONSTRAINT jmap_email_tombstones_mailbox_id_fkey FOREIGN KEY (mailbox_id) REFERENCES public.mailboxes(id) ON DELETE CASCADE;


--
-- Name: jmap_state_tracking jmap_state_tracking_mailbox_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jmap_state_tracking
    ADD CONSTRAINT jmap_state_tracking_mailbox_id_fkey FOREIGN KEY (mailbox_id) REFERENCES public.mailboxes(id) ON DELETE CASCADE;


--
-- Name: link_preview_jobs link_preview_jobs_link_preview_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_preview_jobs
    ADD CONSTRAINT link_preview_jobs_link_preview_id_fkey FOREIGN KEY (link_preview_id) REFERENCES public.link_previews(id) ON DELETE SET NULL;


--
-- Name: link_preview_jobs link_preview_jobs_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_preview_jobs
    ADD CONSTRAINT link_preview_jobs_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: list_members list_members_list_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.list_members
    ADD CONSTRAINT list_members_list_id_fkey FOREIGN KEY (list_id) REFERENCES public.lists(id) ON DELETE CASCADE;


--
-- Name: list_members list_members_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.list_members
    ADD CONSTRAINT list_members_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: list_members list_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.list_members
    ADD CONSTRAINT list_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: lists lists_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT lists_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: mailboxes mailboxes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mailboxes
    ADD CONSTRAINT mailboxes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: message_reactions message_reactions_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_reactions
    ADD CONSTRAINT message_reactions_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: message_reactions message_reactions_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_reactions
    ADD CONSTRAINT message_reactions_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: message_reactions message_reactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_reactions
    ADD CONSTRAINT message_reactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: message_votes message_votes_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_votes
    ADD CONSTRAINT message_votes_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: message_votes message_votes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_votes
    ADD CONSTRAINT message_votes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: messages messages_approved_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_approved_by_id_fkey FOREIGN KEY (approved_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: messages messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: messages messages_flair_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_flair_id_fkey FOREIGN KEY (flair_id) REFERENCES public.community_flairs(id) ON DELETE SET NULL;


--
-- Name: messages messages_link_preview_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_link_preview_id_fkey FOREIGN KEY (link_preview_id) REFERENCES public.link_previews(id) ON DELETE SET NULL;


--
-- Name: messages messages_locked_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_locked_by_id_fkey FOREIGN KEY (locked_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: messages messages_original_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_original_message_id_fkey FOREIGN KEY (original_message_id) REFERENCES public.messages(id) ON DELETE SET NULL;


--
-- Name: messages messages_pinned_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pinned_by_id_fkey FOREIGN KEY (pinned_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: messages messages_quoted_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_quoted_message_id_fkey FOREIGN KEY (quoted_message_id) REFERENCES public.messages(id) ON DELETE SET NULL;


--
-- Name: messages messages_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE SET NULL;


--
-- Name: messages messages_reply_to_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_reply_to_id_fkey FOREIGN KEY (reply_to_id) REFERENCES public.messages(id) ON DELETE SET NULL;


--
-- Name: messages messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: messages messages_shared_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_shared_message_id_fkey FOREIGN KEY (shared_message_id) REFERENCES public.messages(id) ON DELETE SET NULL;


--
-- Name: messaging_federation_account_presence_states messaging_federation_account_presence_states_remote_actor_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_account_presence_states
    ADD CONSTRAINT messaging_federation_account_presence_states_remote_actor_id_fk FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_call_sessions messaging_federation_call_sessions_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_call_sessions
    ADD CONSTRAINT messaging_federation_call_sessions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_call_sessions messaging_federation_call_sessions_local_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_call_sessions
    ADD CONSTRAINT messaging_federation_call_sessions_local_user_id_fkey FOREIGN KEY (local_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_extension_events messaging_federation_extension_events_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_extension_events
    ADD CONSTRAINT messaging_federation_extension_events_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_extension_events messaging_federation_extension_events_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_extension_events
    ADD CONSTRAINT messaging_federation_extension_events_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.messaging_servers(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_invite_states messaging_federation_invite_states_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_invite_states
    ADD CONSTRAINT messaging_federation_invite_states_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_membership_states messaging_federation_membership_states_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_membership_states
    ADD CONSTRAINT messaging_federation_membership_states_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_membership_states messaging_federation_membership_states_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_membership_states
    ADD CONSTRAINT messaging_federation_membership_states_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_peer_policies messaging_federation_peer_policies_updated_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_peer_policies
    ADD CONSTRAINT messaging_federation_peer_policies_updated_by_id_fkey FOREIGN KEY (updated_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: messaging_federation_presence_states messaging_federation_presence_states_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_presence_states
    ADD CONSTRAINT messaging_federation_presence_states_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_presence_states messaging_federation_presence_states_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_presence_states
    ADD CONSTRAINT messaging_federation_presence_states_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.messaging_servers(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_read_cursors messaging_federation_read_cursors_chat_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_read_cursors
    ADD CONSTRAINT messaging_federation_read_cursors_chat_message_id_fkey FOREIGN KEY (chat_message_id) REFERENCES public.chat_messages(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_read_cursors messaging_federation_read_cursors_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_read_cursors
    ADD CONSTRAINT messaging_federation_read_cursors_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_read_cursors messaging_federation_read_cursors_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_read_cursors
    ADD CONSTRAINT messaging_federation_read_cursors_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_read_receipts messaging_federation_read_receipts_chat_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_read_receipts
    ADD CONSTRAINT messaging_federation_read_receipts_chat_message_id_fkey FOREIGN KEY (chat_message_id) REFERENCES public.chat_messages(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_read_receipts messaging_federation_read_receipts_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_read_receipts
    ADD CONSTRAINT messaging_federation_read_receipts_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_room_presence_states messaging_federation_room_presence_states_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_room_presence_states
    ADD CONSTRAINT messaging_federation_room_presence_states_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id) ON DELETE CASCADE;


--
-- Name: messaging_federation_room_presence_states messaging_federation_room_presence_states_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_federation_room_presence_states
    ADD CONSTRAINT messaging_federation_room_presence_states_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: messaging_server_members messaging_server_members_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_server_members
    ADD CONSTRAINT messaging_server_members_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.messaging_servers(id) ON DELETE CASCADE;


--
-- Name: messaging_server_members messaging_server_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_server_members
    ADD CONSTRAINT messaging_server_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: messaging_servers messaging_servers_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messaging_servers
    ADD CONSTRAINT messaging_servers_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: moderation_actions moderation_actions_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions
    ADD CONSTRAINT moderation_actions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: moderation_actions moderation_actions_moderator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions
    ADD CONSTRAINT moderation_actions_moderator_id_fkey FOREIGN KEY (moderator_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: moderation_actions moderation_actions_target_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions
    ADD CONSTRAINT moderation_actions_target_message_id_fkey FOREIGN KEY (target_message_id) REFERENCES public.messages(id) ON DELETE SET NULL;


--
-- Name: moderation_actions moderation_actions_target_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_actions
    ADD CONSTRAINT moderation_actions_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: moderator_notes moderator_notes_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_notes
    ADD CONSTRAINT moderator_notes_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: moderator_notes moderator_notes_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_notes
    ADD CONSTRAINT moderator_notes_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: moderator_notes moderator_notes_target_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_notes
    ADD CONSTRAINT moderator_notes_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: oauth_apps oauth_apps_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_apps
    ADD CONSTRAINT oauth_apps_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: oauth_authorizations oauth_authorizations_app_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_authorizations
    ADD CONSTRAINT oauth_authorizations_app_id_fkey FOREIGN KEY (app_id) REFERENCES public.oauth_apps(id) ON DELETE CASCADE;


--
-- Name: oauth_authorizations oauth_authorizations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_authorizations
    ADD CONSTRAINT oauth_authorizations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: oauth_tokens oauth_tokens_app_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_tokens
    ADD CONSTRAINT oauth_tokens_app_id_fkey FOREIGN KEY (app_id) REFERENCES public.oauth_apps(id) ON DELETE CASCADE;


--
-- Name: oauth_tokens oauth_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_tokens
    ADD CONSTRAINT oauth_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: passkey_credentials passkey_credentials_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passkey_credentials
    ADD CONSTRAINT passkey_credentials_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: password_vault_entries password_vault_entries_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_vault_entries
    ADD CONSTRAINT password_vault_entries_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: password_vault_settings password_vault_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_vault_settings
    ADD CONSTRAINT password_vault_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: platform_updates platform_updates_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_updates
    ADD CONSTRAINT platform_updates_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: poll_options poll_options_poll_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_options
    ADD CONSTRAINT poll_options_poll_id_fkey FOREIGN KEY (poll_id) REFERENCES public.polls(id) ON DELETE CASCADE;


--
-- Name: poll_votes poll_votes_option_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_votes
    ADD CONSTRAINT poll_votes_option_id_fkey FOREIGN KEY (option_id) REFERENCES public.poll_options(id) ON DELETE CASCADE;


--
-- Name: poll_votes poll_votes_poll_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_votes
    ADD CONSTRAINT poll_votes_poll_id_fkey FOREIGN KEY (poll_id) REFERENCES public.polls(id) ON DELETE CASCADE;


--
-- Name: poll_votes poll_votes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_votes
    ADD CONSTRAINT poll_votes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: polls polls_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.polls
    ADD CONSTRAINT polls_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: post_boosts post_boosts_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_boosts
    ADD CONSTRAINT post_boosts_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: post_boosts post_boosts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_boosts
    ADD CONSTRAINT post_boosts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: post_dismissals post_dismissals_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_dismissals
    ADD CONSTRAINT post_dismissals_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: post_dismissals post_dismissals_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_dismissals
    ADD CONSTRAINT post_dismissals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: post_hashtags post_hashtags_hashtag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_hashtags
    ADD CONSTRAINT post_hashtags_hashtag_id_fkey FOREIGN KEY (hashtag_id) REFERENCES public.hashtags(id) ON DELETE CASCADE;


--
-- Name: post_hashtags post_hashtags_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_hashtags
    ADD CONSTRAINT post_hashtags_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: post_likes post_likes_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_likes
    ADD CONSTRAINT post_likes_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: post_likes post_likes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_likes
    ADD CONSTRAINT post_likes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: post_views post_views_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views
    ADD CONSTRAINT post_views_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: post_views post_views_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views
    ADD CONSTRAINT post_views_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: profile_custom_domains profile_custom_domains_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_custom_domains
    ADD CONSTRAINT profile_custom_domains_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: profile_links profile_links_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_links
    ADD CONSTRAINT profile_links_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;


--
-- Name: profile_site_visits profile_site_visits_profile_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_site_visits
    ADD CONSTRAINT profile_site_visits_profile_user_id_fkey FOREIGN KEY (profile_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: profile_site_visits profile_site_visits_viewer_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_site_visits
    ADD CONSTRAINT profile_site_visits_viewer_user_id_fkey FOREIGN KEY (viewer_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: profile_views profile_views_profile_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_views
    ADD CONSTRAINT profile_views_profile_user_id_fkey FOREIGN KEY (profile_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: profile_views profile_views_viewer_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_views
    ADD CONSTRAINT profile_views_viewer_user_id_fkey FOREIGN KEY (viewer_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: profile_widgets profile_widgets_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_widgets
    ADD CONSTRAINT profile_widgets_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;


--
-- Name: registration_checkouts registration_checkouts_invite_code_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.registration_checkouts
    ADD CONSTRAINT registration_checkouts_invite_code_id_fkey FOREIGN KEY (invite_code_id) REFERENCES public.invite_codes(id) ON DELETE SET NULL;


--
-- Name: registration_checkouts registration_checkouts_redeemed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.registration_checkouts
    ADD CONSTRAINT registration_checkouts_redeemed_by_user_id_fkey FOREIGN KEY (redeemed_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: remote_interactions remote_interactions_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.remote_interactions
    ADD CONSTRAINT remote_interactions_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: remote_interactions remote_interactions_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.remote_interactions
    ADD CONSTRAINT remote_interactions_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE SET NULL;


--
-- Name: reports reports_reporter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_reporter_id_fkey FOREIGN KEY (reporter_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: reports reports_reviewed_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_reviewed_by_id_fkey FOREIGN KEY (reviewed_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: rss_items rss_items_feed_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rss_items
    ADD CONSTRAINT rss_items_feed_id_fkey FOREIGN KEY (feed_id) REFERENCES public.rss_feeds(id) ON DELETE CASCADE;


--
-- Name: rss_subscriptions rss_subscriptions_feed_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rss_subscriptions
    ADD CONSTRAINT rss_subscriptions_feed_id_fkey FOREIGN KEY (feed_id) REFERENCES public.rss_feeds(id) ON DELETE CASCADE;


--
-- Name: rss_subscriptions rss_subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rss_subscriptions
    ADD CONSTRAINT rss_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: saved_items saved_items_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_items
    ADD CONSTRAINT saved_items_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: saved_items saved_items_rss_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_items
    ADD CONSTRAINT saved_items_rss_item_id_fkey FOREIGN KEY (rss_item_id) REFERENCES public.rss_items(id) ON DELETE CASCADE;


--
-- Name: saved_items saved_items_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_items
    ADD CONSTRAINT saved_items_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: signing_keys signing_keys_remote_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.signing_keys
    ADD CONSTRAINT signing_keys_remote_actor_id_fkey FOREIGN KEY (remote_actor_id) REFERENCES public.activitypub_actors(id) ON DELETE CASCADE;


--
-- Name: signing_keys signing_keys_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.signing_keys
    ADD CONSTRAINT signing_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: static_site_files static_site_files_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.static_site_files
    ADD CONSTRAINT static_site_files_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: stored_files stored_files_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_files
    ADD CONSTRAINT stored_files_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: stored_folders stored_folders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stored_folders
    ADD CONSTRAINT stored_folders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: subscriptions subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: trust_level_logs trust_level_logs_changed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_level_logs
    ADD CONSTRAINT trust_level_logs_changed_by_user_id_fkey FOREIGN KEY (changed_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: trust_level_logs trust_level_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_level_logs
    ADD CONSTRAINT trust_level_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: trusted_devices trusted_devices_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trusted_devices
    ADD CONSTRAINT trusted_devices_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_activity_stats user_activity_stats_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_activity_stats
    ADD CONSTRAINT user_activity_stats_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_badges user_badges_granted_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_badges
    ADD CONSTRAINT user_badges_granted_by_id_fkey FOREIGN KEY (granted_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: user_badges user_badges_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_badges
    ADD CONSTRAINT user_badges_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_blocks user_blocks_blocked_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_blocked_id_fkey FOREIGN KEY (blocked_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_blocks user_blocks_blocker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_blocker_id_fkey FOREIGN KEY (blocker_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_hidden_messages user_hidden_messages_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_hidden_messages
    ADD CONSTRAINT user_hidden_messages_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: user_hidden_messages user_hidden_messages_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_hidden_messages
    ADD CONSTRAINT user_hidden_messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_integrations user_integrations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_integrations
    ADD CONSTRAINT user_integrations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_mutes user_mutes_muted_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_mutes
    ADD CONSTRAINT user_mutes_muted_id_fkey FOREIGN KEY (muted_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_mutes user_mutes_muter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_mutes
    ADD CONSTRAINT user_mutes_muter_id_fkey FOREIGN KEY (muter_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_post_timestamps user_post_timestamps_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_post_timestamps
    ADD CONSTRAINT user_post_timestamps_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: user_post_timestamps user_post_timestamps_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_post_timestamps
    ADD CONSTRAINT user_post_timestamps_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_profiles user_profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_timeouts user_timeouts_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_timeouts
    ADD CONSTRAINT user_timeouts_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: user_timeouts user_timeouts_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_timeouts
    ADD CONSTRAINT user_timeouts_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: user_timeouts user_timeouts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_timeouts
    ADD CONSTRAINT user_timeouts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_warnings user_warnings_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_warnings
    ADD CONSTRAINT user_warnings_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: user_warnings user_warnings_related_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_warnings
    ADD CONSTRAINT user_warnings_related_message_id_fkey FOREIGN KEY (related_message_id) REFERENCES public.messages(id) ON DELETE SET NULL;


--
-- Name: user_warnings user_warnings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_warnings
    ADD CONSTRAINT user_warnings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_warnings user_warnings_warned_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_warnings
    ADD CONSTRAINT user_warnings_warned_by_id_fkey FOREIGN KEY (warned_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: username_history username_history_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.username_history
    ADD CONSTRAINT username_history_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: vpn_connection_logs vpn_connection_logs_vpn_user_config_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vpn_connection_logs
    ADD CONSTRAINT vpn_connection_logs_vpn_user_config_id_fkey FOREIGN KEY (vpn_user_config_id) REFERENCES public.vpn_user_configs(id) ON DELETE CASCADE;


--
-- Name: vpn_user_configs vpn_user_configs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vpn_user_configs
    ADD CONSTRAINT vpn_user_configs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: vpn_user_configs vpn_user_configs_vpn_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vpn_user_configs
    ADD CONSTRAINT vpn_user_configs_vpn_server_id_fkey FOREIGN KEY (vpn_server_id) REFERENCES public.vpn_servers(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


