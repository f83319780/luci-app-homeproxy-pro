/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage PHASE 4 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     generator/server.uc: server-side orchestrator.
 *
 * The server generator is small enough that splitting it further was
 * not worth the cross-module plumbing: a single iter_servers loop
 * dispatches per-protocol and every shape difference (snell's
 * single-psk inbound vs the generic users[] block) lives in the same
 * module. Keeping it as one file preserves the review boundary that
 * caught sing-box 1.14's `mode`/hysteria obfs regressions in the past.
 *
 * generate_server(dm) -> config object. Pure: no UCI, no file I/O.
 * The 10-line CLI shell (scripts/generate_server.uc) handles the
 * atomic write + sing-box check + mv.
 */

'use strict';

import { isEmpty, strToBool, strToInt, strToTime, buildTLSObject, buildTransportObject } from 'homeproxy';

import { load_tls, load_transport } from '../config/loader.uc';

/* Server-only snell shape. sing-box 1.14 wants a single `psk` field on a
 * snell inbound (one user, one key); the generic users[] block below is
 * for every other protocol. The `mode` field that used to be emitted
 * here was a v6-only option, and v6 is not supported by the target
 * sing-box - sing-box 1.14 rejects it. */
function build_snell_inbound(cfg) {
    return {
        type: 'snell',
        tag: 'cfg-' + cfg.name + '-in',

        listen: cfg.address || '::',
        listen_port: strToInt(cfg.port),
        bind_interface: cfg.bind_interface,
        reuse_addr: strToBool(cfg.reuse_addr),
        tcp_fast_open: strToBool(cfg.tcp_fast_open),
        tcp_multi_path: strToBool(cfg.tcp_multi_path),
        version: strToInt(cfg.snell_version) || 5,
        psk: cfg.password,
        obfs_mode: cfg.snell_obfs_mode
        /* no `mode`: sing-box 1.14 rejects it on a snell inbound (it
        //  was a v6-only option, and v6 is not supported). */
    };
}

/* Generic inbound for everything except snell. The protocol-specific
 * fields (Hysteria obfs, Shadowsocks method, Tuic congestion_control,
 * AnyTLS padding_scheme, ...) are all spelled out explicitly below
 * because sing-box's per-protocol inbound shape is wide and the
 * adapters-on-outbounds pattern does not apply here. */
function build_generic_inbound(cfg) {
    return {
        type: cfg.type,
        tag: 'cfg-' + cfg.name + '-in',

        listen: cfg.address || '::',
        listen_port: strToInt(cfg.port),
        bind_interface: cfg.bind_interface,
        reuse_addr: strToBool(cfg.reuse_addr),
        tcp_fast_open: strToBool(cfg.tcp_fast_open),
        tcp_multi_path: strToBool(cfg.tcp_multi_path),
        udp_fragment: strToBool(cfg.udp_fragment),
        udp_timeout: strToTime(cfg.udp_timeout),
        network: cfg.network,

        /* AnyTLS */
        padding_scheme: cfg.anytls_padding_scheme,

        /* Hysteria (2) */
        up_mbps: strToInt(cfg.hysteria_up_mbps),
        down_mbps: strToInt(cfg.hysteria_down_mbps),
        obfs: cfg.hysteria_obfs_type ? {
            type: cfg.hysteria_obfs_type,
            password: cfg.hysteria_obfs_password,
            min_packet_size: strToInt(cfg.hysteria_obfs_min_packet_size),
            max_packet_size: strToInt(cfg.hysteria_obfs_max_packet_size)
        } : cfg.hysteria_obfs_password,
        ignore_client_bandwidth: strToBool(cfg.hysteria_ignore_client_bandwidth),
        masquerade: cfg.hysteria_masquerade,

        /* Shadowsocks */
        method: (cfg.type === 'shadowsocks') ? cfg.shadowsocks_encrypt_method : null,
        password: (cfg.type in ['shadowsocks', 'shadowtls']) ? cfg.password : null,

        /* Tuic */
        congestion_control: cfg.tuic_congestion_control,
        auth_timeout: strToTime(cfg.tuic_auth_timeout),
        zero_rtt_handshake: strToBool(cfg.tuic_enable_zero_rtt),
        heartbeat: strToTime(cfg.tuic_heartbeat),

        /* AnyTLS / HTTP / Hysteria (2) / Mixed / Socks / Trojan / Tuic / VLESS / VMess */
        users: (cfg.type !== 'shadowsocks') ? [
            {
                name: !(cfg.type in ['http', 'mixed', 'naive', 'socks']) ? 'cfg-' + cfg.name + '-server' : null,
                username: cfg.username,
                password: cfg.password,

                /* Hysteria */
                auth: (cfg.hysteria_auth_type === 'base64') ? cfg.hysteria_auth_payload : null,
                auth_str: (cfg.hysteria_auth_type === 'string') ? cfg.hysteria_auth_payload : null,

                /* Tuic */
                uuid: cfg.uuid,

                /* VLESS / VMess */
                flow: cfg.vless_flow,
                alterId: strToInt(cfg.vmess_alterid)
            }
        ] : null,

        multiplex: (cfg.multiplex === '1') ? {
            enabled: true,
            padding: strToBool(cfg.multiplex_padding),
            brutal: (cfg.multiplex_brutal === '1') ? {
                enabled: true,
                up_mbps: strToInt(cfg.multiplex_brutal_up),
                down_mbps: strToInt(cfg.multiplex_brutal_down)
            } : null
        } : null,

        tls: buildTLSObject(load_tls((k) => cfg[k]), true, cfg),

        transport: buildTransportObject(load_transport((k) => cfg[k]), true)
    };
}

/* --- public entry ------------------------------------------------------ */

/* Build the sing-box server config object. Returns null when no
 * enabled inbound exists (the caller treats that as "service disabled",
 * which the runtime interprets as "do not start the server instance"). */
export function generate_server(dm) {
    const log_level = ((dm.server || {}).settings || {}).log_level || 'warn';

    const config = {
        log: {
            disabled: false,
            level: log_level,
            output: '/var/run/homeproxy/sing-box-s.log',
            timestamp: true
        },
        inbounds: []
    };

    for (let cfg in ((dm.server || {}).inbounds || [])) {
        if (!cfg.enabled)
            continue;

        if (cfg.type === 'snell')
            push(config.inbounds, build_snell_inbound(cfg));
        else
            push(config.inbounds, build_generic_inbound(cfg));
    }

    if (length(config.inbounds) === 0)
        return null;

    config['$schema'] = 'https://sing-box.sagernet.org/schema.json';

    return config;
}