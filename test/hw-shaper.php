<?php
/*
 * Run on a real OPNsense firewall by hw-subtick.sh: the shaper for the
 * hairpin between hosts A and B, two on the firewall's LAN that route
 * to each other through it (a /32 route on each). Pipe 1 (subtick-down)
 * carries B to A, pipe 2 (subtick-up) A to B, each with a queue, as a
 * rule aimed at a pipe goes through its FIFO and not CAKE, and a rule on
 * LAN in; CAKE on both pipes, with its defaults.
 *
 *   php hw-shaper.php pipes A B <rate Mbit/s>
 *   php hw-shaper.php queues A B
 *   php hw-shaper.php rules A B      (or retarget, for rules aimed at the pipes)
 *   php hw-shaper.php cake A B
 *   php hw-shaper.php rate A B <rate Mbit/s>
 *   php hw-shaper.php subtick A B <0|1> [release_us]
 *   php hw-shaper.php direction A B <in|out>
 *
 * Each stage runs in a process of its own, as a model relation only sees
 * the pipes saved before the process started. Apply with hw-subtick.sh's
 * apply (the CAKE page's Apply).
 */
require_once('/usr/local/opnsense/mvc/script/load_phalcon.php');

use OPNsense\Core\Config;
use OPNsense\TrafficShaper\TrafficShaper;
use OPNsense\Cake\Cake;

$stage = $argv[1] ?? '';
$A = $argv[2] ?? '';
$B = $argv[3] ?? '';
$flows = ['down' => [$B, $A, 1], 'up' => [$A, $B, 2]];

function check($mdl)
{
    $bad = 0;
    foreach ($mdl->performValidation() as $msg) {
        echo "invalid: " . $msg->getField() . ": " . $msg->getMessage() . "\n";
        $bad++;
    }
    if ($bad) {
        exit(1);
    }
    $mdl->serializeToConfig();
    Config::getInstance()->save();
}

/* uuids of the subtick pipes or queues, by name */
function named($items)
{
    $found = [];
    foreach ($items->iterateItems() as $uuid => $item) {
        if (str_starts_with((string)$item->description, 'subtick-')) {
            $found[substr((string)$item->description, 8)] = $uuid;
        }
    }
    return $found;
}

if (!in_array($stage, ['pipes', 'queues', 'rules', 'retarget', 'cake', 'rate', 'subtick', 'direction']) ||
    $A == '' || $B == '') {
    echo "usage: hw-shaper.php pipes|queues|rules|retarget|cake|rate|subtick|direction A B [args]\n";
    exit(1);
}

$ts = new TrafficShaper();
$pipes = named($ts->pipes->pipe);
$queues = named($ts->queues->queue);

switch ($stage) {
case 'pipes':
    if (count($pipes) > 0) {
        echo "subtick pipes already exist\n";
        exit(1);
    }
    foreach ($flows as $name => [$src, $dst, $num]) {
        $ts->pipes->pipe->Add()->setNodes([
            'number' => $num,
            'bandwidth' => $argv[4] ?? '100',
            'bandwidthMetric' => 'Mbit',
            'description' => "subtick-$name",
        ]);
    }
    check($ts);
    break;
case 'queues':
    foreach ($flows as $name => [$src, $dst, $num]) {
        $ts->queues->queue->Add()->setNodes([
            'number' => $num,
            'pipe' => $pipes[$name],
            'description' => "subtick-$name",
        ]);
    }
    check($ts);
    break;
case 'rules':
    foreach ($flows as $name => [$src, $dst, $num]) {
        $ts->rules->rule->Add()->setNodes([
            'sequence' => $num,
            'interface' => 'lan',
            'direction' => 'in',
            'proto' => 'ip',
            'source' => $src,
            'destination' => $dst,
            'target' => $queues[$name],
            'description' => "subtick-$name",
        ]);
    }
    check($ts);
    break;
case 'retarget':
    foreach ($ts->rules->rule->iterateItems() as $uuid => $r) {
        $name = substr((string)$r->description, 8);
        if (str_starts_with((string)$r->description, 'subtick-') && isset($queues[$name])) {
            $r->target = $queues[$name];
        }
    }
    check($ts);
    break;
case 'cake':
    $cake = new Cake();
    foreach ($pipes as $name => $uuid) {
        $cake->pipes->pipe->Add()->setNodes(['pipe' => $uuid, 'description' => "subtick-$name"]);
    }
    check($cake);
    break;
case 'rate':
    foreach ($ts->pipes->pipe->iterateItems() as $uuid => $p) {
        if (in_array($uuid, $pipes)) {
            $p->bandwidth = $argv[4];
        }
    }
    check($ts);
    break;
case 'direction':
    /* in: dummynet's thread forwards what it releases (ip_input() again,
     * pf, routing, output); out: only what is left of ip_output() */
    foreach ($ts->rules->rule->iterateItems() as $uuid => $r) {
        if (str_starts_with((string)$r->description, 'subtick-')) {
            $r->direction = $argv[4];
        }
    }
    check($ts);
    break;
case 'subtick':
    $cake = new Cake();
    $cake->general->subtick = $argv[4];
    if (isset($argv[5])) {
        $cake->general->release_us = $argv[5];
    }
    check($cake);
    break;
}
echo "$stage OK\n";
