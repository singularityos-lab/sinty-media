const c = @import("../c.zig").c;

const PAD = c.GST_PADDING;

pub const Transceiver = extern struct {
    pub const Header = c.GstWebRTCRTPTransceiver;

    parent: c.GstObject,
    mline: c.guint,
    mid: [*c]u8,
    stopped: c.gboolean,
    sender: ?*Sender,
    receiver: ?*Receiver,
    direction: c.GstWebRTCRTPTransceiverDirection,
    current_direction: c.GstWebRTCRTPTransceiverDirection,
    codec_preferences: [*c]c.GstCaps,
    kind: c.GstWebRTCKind,
    padding: [PAD]c.gpointer,
};

pub const TransceiverClass = extern struct {
    pub const Header = c.GstWebRTCRTPTransceiverClass;

    parent: c.GstObjectClass,
    padding: [PAD]c.gpointer,
};

pub const Sender = extern struct {
    pub const Header = c.GstWebRTCRTPSender;

    parent: c.GstObject,
    transport: ?*DtlsTransport,
    send_encodings: ?*c.GArray,
    priority: c.GstWebRTCPriorityType,
    padding: [PAD]c.gpointer,
};

pub const SenderClass = extern struct {
    pub const Header = c.GstWebRTCRTPSenderClass;

    parent: c.GstObjectClass,
    padding: [PAD]c.gpointer,
};

pub const Receiver = extern struct {
    pub const Header = c.GstWebRTCRTPReceiver;

    parent: c.GstObject,
    transport: ?*DtlsTransport,
    padding: [PAD]c.gpointer,
};

pub const ReceiverClass = extern struct {
    pub const Header = c.GstWebRTCRTPReceiverClass;

    parent: c.GstObjectClass,
    padding: [PAD]c.gpointer,
};

pub const DtlsTransport = extern struct {
    pub const Header = c.GstWebRTCDTLSTransport;

    parent: c.GstObject,
    transport: [*c]c.GstWebRTCICETransport,
    state: c.GstWebRTCDTLSTransportState,
    client: c.gboolean,
    session_id: c.guint,
    dtlssrtpenc: [*c]c.GstElement,
    dtlssrtpdec: [*c]c.GstElement,
    padding: [PAD]c.gpointer,
};

pub const DtlsTransportClass = extern struct {
    pub const Header = c.GstWebRTCDTLSTransportClass;

    parent: c.GstObjectClass,
    padding: [PAD]c.gpointer,
};

pub const DataChannel = extern struct {
    pub const Header = c.GstWebRTCDataChannel;

    parent: c.GObject,
    lock: c.GMutex,
    label: [*c]u8,
    ordered: c.gboolean,
    max_packet_lifetime: c.guint,
    max_retransmits: c.guint,
    protocol: [*c]u8,
    negotiated: c.gboolean,
    id: c.gint,
    priority: c.GstWebRTCPriorityType,
    ready_state: c.GstWebRTCDataChannelState,
    buffered_amount: c.guint64,
    buffered_amount_low_threshold: c.guint64,
    padding: [PAD]c.gpointer,
};

pub const DataChannelClass = extern struct {
    pub const Header = c.GstWebRTCDataChannelClass;

    parent: c.GObjectClass,
    send_data: ?*const fn (*DataChannel, ?*c.GBytes, [*c][*c]c.GError) callconv(.c) c.gboolean,
    send_string: ?*const fn (*DataChannel, [*c]const u8, [*c][*c]c.GError) callconv(.c) c.gboolean,
    close: ?*const fn (*DataChannel) callconv(.c) void,
    padding: [PAD]c.gpointer,
};

pub const SctpTransport = extern struct {
    pub const Header = c.GstWebRTCSCTPTransport;

    parent: c.GstObject,
};

pub const SctpTransportClass = extern struct {
    pub const Header = c.GstWebRTCSCTPTransportClass;

    parent: c.GstObjectClass,
};
