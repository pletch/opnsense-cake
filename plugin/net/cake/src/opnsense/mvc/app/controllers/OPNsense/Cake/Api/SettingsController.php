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

use OPNsense\Base\ApiMutableModelControllerBase;

/**
 * Class SettingsController Handles the CAKE settings of traffic shaper pipes
 * @package OPNsense\Cake
 */
class SettingsController extends ApiMutableModelControllerBase
{
    protected static $internalModelName = 'cake';
    protected static $internalModelClass = '\OPNsense\Cake\Cake';

    /**
     * Search CAKE pipe settings
     * @return array list of found items
     * @throws \ReflectionException when not bound to model
     */
    public function searchPipesAction()
    {
        return $this->searchBase("pipes.pipe");
    }

    /**
     * Retrieve CAKE pipe settings or return defaults
     * @param $uuid item unique id
     * @return array CAKE pipe content
     * @throws \ReflectionException when not bound to model
     */
    public function getPipeAction($uuid = null)
    {
        return $this->getBase("pipe", "pipes.pipe", $uuid);
    }

    /**
     * Add CAKE settings for a pipe
     * @return array save result + validation output
     * @throws \OPNsense\Base\ValidationException when field validations fail
     * @throws \ReflectionException when not bound to model
     */
    public function addPipeAction()
    {
        return $this->addBase("pipe", "pipes.pipe");
    }

    /**
     * Update CAKE settings of a pipe
     * @param string $uuid internal id
     * @return array save result + validation output
     * @throws \OPNsense\Base\ValidationException when field validations fail
     * @throws \ReflectionException when not bound to model
     */
    public function setPipeAction($uuid)
    {
        return $this->setBase("pipe", "pipes.pipe", $uuid);
    }

    /**
     * Delete CAKE settings of a pipe, it returns to its own scheduler
     * @param string $uuid internal id
     * @return array save status
     * @throws \OPNsense\Base\ValidationException when field validations fail
     * @throws \ReflectionException when not bound to model
     */
    public function delPipeAction($uuid)
    {
        return $this->delBase("pipes.pipe", $uuid);
    }

    /**
     * Toggle CAKE on a pipe
     * @param string $uuid internal id
     * @param string $enabled desired state enabled(1)/disabled(0), leave empty for toggle
     * @return array save result
     * @throws \OPNsense\Base\ValidationException when field validations fail
     * @throws \ReflectionException when not bound to model
     */
    public function togglePipeAction($uuid, $enabled = null)
    {
        return $this->toggleBase("pipes.pipe", $uuid, $enabled);
    }
}
