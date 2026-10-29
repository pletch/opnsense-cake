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

namespace OPNsense\Cake\Api;

use OPNsense\Base\ApiControllerBase;
use OPNsense\Core\Backend;

/**
 * Class ServiceController
 * @package OPNsense\Cake
 */
class ServiceController extends ApiControllerBase
{
    /**
     * reload the traffic shaper, the dnctl wrapper switches CAKE pipes over
     */
    public function reconfigureAction()
    {
        if ($this->request->isPost()) {
            return $this->reload(new Backend());
        }

        return ["status" => "failed"];
    }

    /**
     * let the wrapper load dummynet-st again after a crash kept it out, and reload the
     * shaper; Apply alone leaves it out, so that it does not undo that by accident
     */
    public function retryAction()
    {
        if ($this->request->isPost()) {
            $backend = new Backend();
            $backend->configdRun('cake retry');
            return $this->reload($backend);
        }

        return ["status" => "failed"];
    }

    private function reload($backend)
    {
        $backend->configdRun('template reload OPNsense/Shaper');
        $backend->configdRun('template reload OPNsense/IPFW');

        $result = trim($backend->configdRun("shaper reload"));
        if ($result != "OK") {
            return ["status" => "error reloading shaper (" . $result . ")"];
        }

        $result = trim($backend->configdRun("ipfw reload"));
        if ($result != "OK") {
            return ["status" => "error reloading ipfw (" . $result . ")"];
        }

        return ["status" => "ok"];
    }

    /**
     * kernel module and scheduler status
     */
    public function statusAction()
    {
        $result = json_decode((new Backend())->configdRun("cake status"), true);
        return $result != null ? $result : ["status" => "failed"];
    }
}
