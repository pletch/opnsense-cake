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
    });
</script>

<div class="alert alert-info" role="alert" id="cake_status">
    {{ lang._('Fetching the CAKE status...') }}
</div>

<div class="content-box">
    {{ partial('layout_partials/base_bootgrid_table', formGridPipe) }}
</div>

{{ partial('layout_partials/base_apply_button', {'data_endpoint': '/api/cake/service/reconfigure'}) }}
{{ partial('layout_partials/base_dialog', ['fields': formDialogPipe, 'id': formGridPipe['edit_dialog_id'], 'label': lang._('Edit CAKE pipe')]) }}
