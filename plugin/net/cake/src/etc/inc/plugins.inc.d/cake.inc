<?php

/*
 * Copyright (C) 2026 Tim Pletcher
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 * OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/**
 * The CAKE entry of the services list (and the dashboard's Services widget), while a
 * CAKE entry is enabled: running when every enabled entry's pipe uses CAKE. CAKE has no
 * daemon, so the dnctl wrapper keeps a placeholder process running, with its PID in
 * /var/run/cake.pid, while it has set them all up (lib.set_active). Restart reloads the
 * shaper, which also replaces a dn_cake.ko an upgrade left loaded.
 */
function cake_services()
{
    $services = [];

    foreach ((new \OPNsense\Cake\Cake())->pipes->pipe->iterateItems() as $pipe) {
        if ((string)$pipe->enabled == '1') {
            $services[] = [
                'description' => gettext('CAKE shaper'),
                'configd' => [
                    'restart' => ['shaper reload'],
                ],
                'pidfile' => '/var/run/cake.pid',
                'locked' => true,
                'name' => 'cake',
            ];
            break;
        }
    }

    return $services;
}
