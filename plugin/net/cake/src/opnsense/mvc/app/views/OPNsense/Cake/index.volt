{#
 # Copyright (c) 2026 Tim Pletcher
 # All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without modification,
 # are permitted provided that the following conditions are met:
 #
 # 1. Redistributions of source code must retain the above copyright notice,
 #    this list of conditions and the following disclaimer.
 #
 # 2. Redistributions in binary form must reproduce the above copyright notice,
 #    this list of conditions and the following disclaimer in the documentation
 #    and/or other materials provided with the distribution.
 #
 # THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 # INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 # AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 # AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 # OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 # SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 # INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 # CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 # ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 # POSSIBILITY OF SUCH DAMAGE.
 #}

<script>
    $( document ).ready(function() {
        function fmtRate(bits) {
            if (!bits) {
                return "{{ lang._('unshaped') }}";
            }
            return bits >= 1e9 ? (bits / 1e9).toFixed(2) + " Gbit/s" : (bits / 1e6).toFixed(1) + " Mbit/s";
        }

        function fmtTime(us) {
            return (us / 1000).toFixed(us < 10000 ? 2 : 1) + " ms";
        }

        function fmtBytes(bytes) {
            let units = ["B", "KB", "MB", "GB", "TB"], i = 0;
            while (bytes >= 1000 && i < units.length - 1) {
                bytes /= 1000;
                i++;
            }
            return (i ? bytes.toFixed(1) : bytes) + " " + units[i];
        }

        /* rows of a pipe's statistics table, one column per tin, as tc -s shows them */
        const statRows = [
            ["{{ lang._('Rate threshold') }}", t => fmtRate(t.rate)],
            ["{{ lang._('Target') }}", t => fmtTime(t.target)],
            ["{{ lang._('Interval') }}", t => fmtTime(t.interval)],
            ["{{ lang._('Peak delay') }}", t => fmtTime(t.peak_delay)],
            ["{{ lang._('Average delay') }}", t => fmtTime(t.avg_delay)],
            ["{{ lang._('Base delay') }}", t => fmtTime(t.base_delay)],
            ["{{ lang._('Packets sent') }}", t => t.pkts],
            ["{{ lang._('Bytes sent') }}", t => fmtBytes(t.bytes)],
            ["{{ lang._('Backlog') }}", t => t.backlog + " / " + fmtBytes(t.backlog_bytes)],
            ["{{ lang._('Drops') }}", t => t.drops],
            ["{{ lang._('ECN marks') }}", t => t.marks],
            ["{{ lang._('ACK filter drops') }}", t => t.ack_drops],
            ["{{ lang._('Sparse flows') }}", t => t.sparse],
            ["{{ lang._('Bulk flows') }}", t => t.bulk],
            ["{{ lang._('Decaying flows') }}", t => t.decaying],
            ["{{ lang._('Unresponsive flows') }}", t => t.unresponsive],
            ["{{ lang._('Hash collisions') }}", t => t.collisions]
        ];

        /*
         * Fixed column widths, so that the columns line up between pipes
         * (with the same number of tins) and do not move as values change
         */
        function statCols(n) {
            let $cols = $("<colgroup/>").append($("<col/>").css("width", "25%"));
            for (let i = 0; i < n; i++) {
                $cols.append($("<col/>").css("width", (75 / n) + "%"));
            }
            return $cols;
        }

        /**
         * per-tin statistics of each pipe that uses CAKE
         */
        function showStats(data) {
            let $stats = $("#cake_stats").empty();
            if (!data.usable || !data.schedulers || data.schedulers.length == 0) {
                $stats.hide();
                return;
            }
            if (!data.stats_available) {
                $stats.append($("<div/>").addClass("alert alert-info").text(
                    "{{ lang._('Statistics need cake-kmod 1.3 or later.') }}"
                )).show();
                return;
            }
            data.schedulers.forEach(function(sched) {
                let name = "{{ lang._('Pipe') }} " + sched.sched + (sched.description ? ": " + sched.description : "");
                if (sched.instances.length == 0) {
                    $stats.append($("<div/>").addClass("content-box").append(
                        $("<div/>").addClass("alert alert-info").css("margin", "0").text(
                            name + ": " + "{{ lang._('no traffic yet') }}"
                        )
                    ));
                }
                sched.instances.forEach(function(tins, inst) {
                    let title = name +
                        (sched.instances.length > 1 ? " ({{ lang._('instance') }} " + (inst + 1) + ")" : "");
                    let $head = $("<tr/>").append($("<th/>").text(title));
                    tins.forEach(t => $head.append($("<th/>").text(t.name)));
                    let $body = $("<tbody/>");
                    statRows.forEach(function(row) {
                        let $tr = $("<tr/>").append($("<td/>").text(row[0]));
                        tins.forEach(t => $tr.append($("<td/>").text(row[1](t))));
                        $body.append($tr);
                    });
                    $stats.append($("<div/>").addClass("content-box").append(
                        $("<div/>").addClass("table-responsive").append(
                            $("<table/>").addClass("table table-condensed table-striped cake-stats")
                                .append(statCols(tins.length), $("<thead/>").append($head), $body)
                        )
                    ));
                });
            });
            $stats.show();
        }

        /**
         * show whether the kernel module can be used
         */
        function updateStatus() {
            ajaxGet("/api/cake/service/status", {}, function(data, status) {
                let $status = $("#cake_status");
                $status.removeClass("alert-info alert-success alert-warning");
                if (data.usable) {
                    $status.addClass("alert-success").text(
                        "{{ lang._('The CAKE kernel module is loaded, %s pipes use it.') }}"
                        .replace("%s", data.schedulers.length)
                    );
                } else if (data.status == "failed") {
                    $status.addClass("alert-warning").text("{{ lang._('Unable to fetch the CAKE status.') }}");
                } else {
                    $status.addClass("alert-warning").text(
                        "{{ lang._('The CAKE kernel module cannot be used: %s. Pipes keep their own scheduler.') }}"
                        .replace("%s", data.reason)
                    );
                }

                let $hz = $("#cake_hz");
                if (data.hz && data.hz < 1000) {
                    let vm = data.vm_guest && data.vm_guest != "none";
                    $hz.text(
                        (vm ? "{{ lang._('kern.hz is %s, the FreeBSD default in a virtual machine.') }}"
                            : "{{ lang._('kern.hz is %s.') }}").replace("%s", data.hz) + " " +
                        "{{ lang._('The shaper releases traffic and measures delay in clock ticks, so CAKE and FQ-CoDel control latency more coarsely. Add the tunable kern.hz with value 1000 under System: Settings: Tunables and reboot, a second time if it still shows %s.') }}"
                        .replace("%s", data.hz)
                    ).append(
                        " ", $("<a/>").attr("href", "/ui/core/tunables").text("{{ lang._('Open Tunables') }}")
                    ).show();
                } else {
                    $hz.hide();
                }

                let $warnings = $("#cake_warnings");
                if (data.warnings && data.warnings.length) {
                    $warnings.empty().append(
                        $("<ul/>").css("margin-bottom", "0").append(
                            data.warnings.map(function(w) { return $("<li/>").text(w); })
                        )
                    ).show();
                } else {
                    $warnings.hide();
                }

                showStats(data);
            });
        }

        $("#{{formGridPipe['table_id']}}").UIBootgrid(
            {   search:'/api/cake/settings/search_pipes',
                get:'/api/cake/settings/get_pipe/',
                set:'/api/cake/settings/set_pipe/',
                add:'/api/cake/settings/add_pipe/',
                del:'/api/cake/settings/del_pipe/',
                toggle:'/api/cake/settings/toggle_pipe/'
            }
        );

        $("#reconfigureAct").SimpleActionButton({
            onAction: function() {
                updateStatus();
            }
        });

        updateStatus();
        /* keep the statistics current while the page is visible */
        setInterval(function() {
            if (!document.hidden) {
                updateStatus();
            }
        }, 5000);
    });
</script>

<div class="alert alert-info" role="alert" id="cake_status">
    {{ lang._('Fetching the CAKE status...') }}
</div>

<div class="alert alert-warning" role="alert" id="cake_hz" style="display: none;"></div>

<div class="alert alert-warning" role="alert" id="cake_warnings" style="display: none;"></div>

<div class="content-box">
    {{ partial('layout_partials/base_bootgrid_table', formGridPipe) }}
</div>

{{ partial('layout_partials/base_apply_button', {'data_endpoint': '/api/cake/service/reconfigure'}) }}

<style>
    table.cake-stats {
        table-layout: fixed;
        font-variant-numeric: tabular-nums;
    }
</style>

<div id="cake_stats" style="display: none;"></div>
{{ partial('layout_partials/base_dialog', ['fields': formDialogPipe, 'id': formGridPipe['edit_dialog_id'], 'label': lang._('Edit CAKE pipe')]) }}
